## Queued streaming HTTP downloads on a ``SigilChronosThread``.

import std/[deques, tables]
import chronos
import chronos/apps/http/httpclient
import ../[actors, core]

type
  ChronosDownloadRequest = object
    id: uint64
    url: string
  ChronosDownloadTask = ref object
    future: Future[void].Raising([])
    cancelled: bool
  ChronosDownloadQueue* = ref object of AgentActor
    pending: Deque[ChronosDownloadRequest]
    active: Table[uint64, ChronosDownloadTask]
    maxActive, maxPending, maxBody: int
    closed, pumping: bool

proc chronosDownloadHeaders*(queue: ChronosDownloadQueue, id: uint64,
    status: int, headers: Table[string, string]) {.signal.}
proc chronosDownloadData*(queue: ChronosDownloadQueue, id: uint64,
    data: string) {.signal.}
proc chronosDownloadFinished*(queue: ChronosDownloadQueue, id: uint64,
    error: string) {.signal.}

proc newChronosDownloadQueue*(maxActive = 4, maxPending = 128,
    maxBody = 64 * 1024 * 1024): ChronosDownloadQueue =
  ## Create an actor; move it to a SigilChronosThread before submitting work.
  if maxActive <= 0 or maxPending <= 0 or maxBody <= 0:
    raise newException(ValueError, "invalid download queue configuration")
  ChronosDownloadQueue(maxActive: maxActive, maxPending: maxPending,
    maxBody: maxBody, pending: initDeque[ChronosDownloadRequest](),
    active: initTable[uint64, ChronosDownloadTask]())

proc pump(queue: ChronosDownloadQueue) {.gcsafe.}

proc perform(queue: ChronosDownloadQueue, item: ChronosDownloadRequest,
    task: ChronosDownloadTask) {.async: (raises: []).} =
  var
    failure = ""
    session: HttpSessionRef
    request: HttpClientRequestRef
    response: HttpClientResponseRef
    reader: HttpBodyReader
  try:
    session = HttpSessionRef.new(flags = {HttpClientFlag.NewConnectionAlways})
    request = HttpClientRequestRef.new(session, item.url).valueOr:
      raise newException(ValueError, error)
    response = await request.send()
    var headers = initTable[string, string]()
    for name, value in response.headers.stringItems():
      if name in headers: headers[name].add(", " & value)
      else: headers[name] = value
    if not task.cancelled:
      {.cast(raises: [CatchableError]).}:
        emit queue.chronosDownloadHeaders(item.id, response.status, headers)
    reader = response.getBodyReader()
    var total = 0
    while not task.cancelled:
      var data = newString(16 * 1024)
      let count = await reader.readOnce(addr data[0], data.len)
      if count == 0: break
      if count > queue.maxBody - total:
        raise newException(IOError, "HTTP response exceeds body limit")
      total += count
      data.setLen(count)
      {.cast(raises: [CatchableError]).}:
        emit queue.chronosDownloadData(item.id, data)
    if not task.cancelled:
      await reader.closeWait()
      reader = nil
      await response.finish()
  except CancelledError:
    task.cancelled = true
  except CatchableError as error:
    failure = error.msg
  finally:
    if not reader.isNil: await noCancel(reader.closeWait())
    if not response.isNil: await noCancel(response.closeWait())
    if not request.isNil: await noCancel(request.closeWait())
    if not session.isNil: await noCancel(session.closeWait())
    queue.active.del(item.id)
    {.cast(raises: []).}:
      emit queue.chronosDownloadFinished(item.id,
        if task.cancelled: "cancelled" else: failure)
      queue.pump()

proc pump(queue: ChronosDownloadQueue) {.gcsafe.} =
  if queue.pumping: return
  queue.pumping = true
  try:
    while not queue.closed and queue.pending.len > 0 and
        queue.active.len < queue.maxActive:
      let item = queue.pending.popFirst()
      let task = ChronosDownloadTask()
      queue.active[item.id] = task
      task.future = queue.perform(item, task)
  finally:
    queue.pumping = false

proc enqueueChronosDownload*(queue: ChronosDownloadQueue, id: uint64,
    url: string) {.slot.} =
  ## Submit a unique nonzero ID. Completion and rejection use the same signal.
  if queue.closed:
    emit queue.chronosDownloadFinished(id, "download queue is closed")
    return
  if id == 0 or url.len == 0 or id in queue.active:
    emit queue.chronosDownloadFinished(id, "invalid or duplicate download request")
    return
  for item in queue.pending:
    if item.id == id:
      emit queue.chronosDownloadFinished(id, "invalid or duplicate download request")
      return
  if queue.pending.len >= queue.maxPending:
    emit queue.chronosDownloadFinished(id, "download queue is full")
    return
  queue.pending.addLast(ChronosDownloadRequest(id: id, url: url))
  queue.pump()

proc cancelChronosDownload*(queue: ChronosDownloadQueue, id: uint64) {.slot.} =
  ## Cancel a pending or active download. Blocking DNS cannot be interrupted.
  if id in queue.active:
    let task = queue.active[id]
    task.cancelled = true
    if not task.future.isNil: task.future.cancelSoon()
  else:
    var pending = initDeque[ChronosDownloadRequest]()
    var found = false
    while queue.pending.len > 0:
      let item = queue.pending.popFirst()
      if item.id == id: found = true
      else: pending.addLast(item)
    queue.pending = move pending
    if found: emit queue.chronosDownloadFinished(id, "cancelled")

proc closeChronosDownloads*(queue: ChronosDownloadQueue) {.slot.} =
  ## Reject new work and cancel existing requests; retain the actor until done.
  if queue.closed: return
  queue.closed = true
  while queue.pending.len > 0:
    let item = queue.pending.popFirst()
    emit queue.chronosDownloadFinished(item.id, "cancelled")
  for task in queue.active.values:
    task.cancelled = true
    if not task.future.isNil: task.future.cancelSoon()
