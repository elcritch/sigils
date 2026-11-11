## Queued HTTP downloads on an ``AsyncSigilThread`` using std/httpclient.
## Construct and use the actor on its owning async dispatcher thread.

import std/[asyncdispatch, asyncstreams, deques, strutils, tables]
import ../[actors, core]
import stdlibClient

type
  AsyncDownloadRequest = object
    id: uint64
    url: string
  AsyncDownloadTask = ref object
    id: uint64
    client: AsyncHttpClient
    cancelled, finished, watching: bool
  AsyncDownloadQueue* = ref object of AgentActor
    pending: Deque[AsyncDownloadRequest]
    active: Table[uint64, AsyncDownloadTask]
    maxActive, maxPending, maxBody: int
    closed, pumping: bool

proc asyncDownloadHeaders*(queue: AsyncDownloadQueue, id: uint64,
    status: int, headers: Table[string, string]) {.signal.}
proc asyncDownloadData*(queue: AsyncDownloadQueue, id: uint64,
    data: string) {.signal.}
proc asyncDownloadFinished*(queue: AsyncDownloadQueue, id: uint64,
    error: string) {.signal.}

proc newAsyncDownloadQueue*(maxActive = 4, maxPending = 128,
    maxBody = 64 * 1024 * 1024): AsyncDownloadQueue =
  ## Create an actor; move it to an AsyncSigilThread before submitting work.
  if maxActive <= 0 or maxPending <= 0 or maxBody <= 0:
    raise newException(ValueError, "invalid download queue configuration")
  AsyncDownloadQueue(maxActive: maxActive, maxPending: maxPending,
    maxBody: maxBody, pending: initDeque[AsyncDownloadRequest](),
    active: initTable[uint64, AsyncDownloadTask]())

proc pump(queue: AsyncDownloadQueue)

proc perform(queue: AsyncDownloadQueue, item: AsyncDownloadRequest,
    task: AsyncDownloadTask) {.async.} =
  var failure = ""
  try:
    let response = await task.client.get(item.url)
    var headers = initTable[string, string]()
    for name, value in response.headers.pairs:
      if name in headers: headers[name].add(", " & value)
      else: headers[name] = value
    if not task.cancelled:
      emit queue.asyncDownloadHeaders(item.id, response.code.int, headers)
    var total = 0
    while not task.cancelled:
      let (hasData, data) = await response.bodyStream.read()
      if not hasData: break
      if data.len > queue.maxBody - total:
        raise newException(IOError, "HTTP response exceeds body limit")
      total += data.len
      emit queue.asyncDownloadData(item.id, data)
  except CatchableError as error:
    failure = error.msg
  finally:
    task.finished = true
    task.client.close()
    queue.active.del(item.id)
    emit queue.asyncDownloadFinished(item.id,
      if task.cancelled: "cancelled" else: failure)
    queue.pump()

proc pump(queue: AsyncDownloadQueue) =
  if queue.pumping: return
  queue.pumping = true
  try:
    while not queue.closed and queue.pending.len > 0 and
        queue.active.len < queue.maxActive:
      let item = queue.pending.popFirst()
      try:
        let task = AsyncDownloadTask(id: item.id, client: newAsyncHttpClient())
        queue.active[item.id] = task
        asyncCheck queue.perform(item, task)
      except CatchableError as error:
        queue.active.del(item.id)
        emit queue.asyncDownloadFinished(item.id, error.msg)
  finally:
    queue.pumping = false

proc enqueueAsyncDownload*(queue: AsyncDownloadQueue, id: uint64,
    url: string) {.slot.} =
  ## Submit a unique nonzero ID. Completion and rejection use the same signal.
  if queue.closed:
    emit queue.asyncDownloadFinished(id, "download queue is closed")
    return
  if id == 0 or url.len == 0 or url.contains({'\r', '\n'}) or id in queue.active:
    emit queue.asyncDownloadFinished(id, "invalid or duplicate download request")
    return
  for item in queue.pending:
    if item.id == id:
      emit queue.asyncDownloadFinished(id, "invalid or duplicate download request")
      return
  if queue.pending.len >= queue.maxPending:
    emit queue.asyncDownloadFinished(id, "download queue is full")
    return
  queue.pending.addLast(AsyncDownloadRequest(id: id, url: url))
  queue.pump()

proc watchCancellation(task: AsyncDownloadTask) {.async.} =
  # std/httpclient cannot close its socket until async dial has completed.
  while not task.finished:
    task.client.close()
    if not task.finished:
      await sleepAsync(10)

proc cancelTask(task: AsyncDownloadTask) =
  task.cancelled = true
  task.client.close()
  if not task.finished and not task.watching:
    task.watching = true
    asyncCheck watchCancellation(task)

proc cancelAsyncDownload*(queue: AsyncDownloadQueue, id: uint64) {.slot.} =
  ## Cancel a pending or active download. Blocking DNS cannot be interrupted.
  if id in queue.active:
    let task = queue.active[id]
    task.cancelTask()
  else:
    var pending = initDeque[AsyncDownloadRequest]()
    var found = false
    while queue.pending.len > 0:
      let item = queue.pending.popFirst()
      if item.id == id: found = true
      else: pending.addLast(item)
    queue.pending = move pending
    if found: emit queue.asyncDownloadFinished(id, "cancelled")

proc closeAsyncDownloads*(queue: AsyncDownloadQueue) {.slot.} =
  ## Reject new work and cancel existing requests; retain the actor until done.
  if queue.closed: return
  queue.closed = true
  while queue.pending.len > 0:
    let item = queue.pending.popFirst()
    emit queue.asyncDownloadFinished(item.id, "cancelled")
  var tasks: seq[AsyncDownloadTask]
  for task in queue.active.values:
    tasks.add(task)
  for task in tasks:
    task.cancelTask()
