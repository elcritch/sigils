## Queued streaming HTTP/1.1 GET requests on a selector scheduler.
## HTTPS requires a TLS transport and is not yet supported.

import std/[deques, net, strutils, tables, times, uri]
import ../[agents, core, threadProxies, threadSelectors]
import ../net/resolver
import ../transports/selectorStream
import responseParser

type
  HttpDownloadQueue* = ref object of Agent
    thread: SigilSelectorThreadPtr
    resolver: AgentProxy[DnsResolver]
    pending: Deque[HttpDownload]
    active: Table[uint64, HttpDownload]
    maxActive, maxPending, timeoutMs, maxBody: int
    nextId: uint64
    stopped: bool
    pumping: bool
  HttpDownload = ref object of Agent
    owner: HttpDownloadQueue
    id: uint64
    host, target: string
    port: Port
    addresses: seq[string]
    addressIndex: int
    stream: SelectorStream
    retryTimer: SigilTimer
    parser: HttpResponseParser
    reportedHeaders, done: bool

proc resolveRequested(queue: HttpDownloadQueue, id: uint64,
    host: string) {.signal.}
proc downloadHeaders*(queue: HttpDownloadQueue, id: uint64, status: int,
    headers: Table[string, string]) {.signal.}
proc downloadData*(queue: HttpDownloadQueue, id: uint64,
    data: string) {.signal.}
proc downloadFinished*(queue: HttpDownloadQueue, id: uint64,
    error: string) {.signal.}

proc resolved(queue: HttpDownloadQueue, answer: DnsResult) {.slot.}
proc onConnected(job: HttpDownload) {.slot.}
proc onRetry(job: HttpDownload) {.slot.}
proc onData(job: HttpDownload, data: string) {.slot.}
proc onClosed(job: HttpDownload, error: string) {.slot.}
proc pump(queue: HttpDownloadQueue)

proc newHttpDownloadQueue*(thread: SigilSelectorThreadPtr,
    dns: AgentProxy[DnsResolver], maxActive = 4, maxPending = 128,
    timeoutMs = 30_000, maxBody = 64 * 1024 * 1024): HttpDownloadQueue =
  ## Construct on the selector thread, with a resolver moved to a worker.
  if thread.isNil or dns.isNil or maxActive <= 0 or maxPending <= 0 or
      timeoutMs <= 0 or maxBody <= 0:
    raise newException(ValueError, "invalid HTTP queue configuration")
  result = HttpDownloadQueue(thread: thread, resolver: dns,
    maxActive: maxActive, maxPending: maxPending, timeoutMs: timeoutMs,
    maxBody: maxBody, pending: initDeque[HttpDownload](),
    active: initTable[uint64, HttpDownload]())
  connectThreaded(result, resolveRequested, dns, resolveDns)
  connectThreaded(dns, dnsResolved, result, HttpDownloadQueue.resolved())

proc finish(job: HttpDownload, error: string) =
  if job.done: return
  job.done = true
  let queue = job.owner
  if not job.retryTimer.isNil:
    job.retryTimer.cancel(queue.thread.toSigilThread())
    job.retryTimer = nil
  if not job.stream.isNil: job.stream.close()
  queue.active.del(job.id)
  job.owner = nil
  emit queue.downloadFinished(job.id, error)
  queue.pump()

proc startConnection(job: HttpDownload) =
  while job.addressIndex < job.addresses.len:
    let address = job.addresses[job.addressIndex]
    job.addressIndex.inc()
    try:
      job.stream = connectTcp(job.owner.thread, address, job.port)
      connect(job.stream, streamConnected, job, onConnected)
      connect(job.stream, streamData, job, onData)
      connect(job.stream, streamClosed, job, onClosed)
      job.stream.setDeadline(job.owner.timeoutMs)
      return
    except CatchableError:
      discard
  job.finish("could not connect to any resolved address")

proc onRetry(job: HttpDownload) {.slot.} =
  job.retryTimer = nil
  if not job.done:
    job.startConnection()

proc resolved(queue: HttpDownloadQueue, answer: DnsResult) {.slot.} =
  if not queue.active.hasKey(answer.id): return
  let job = queue.active[answer.id]
  if answer.error.len > 0:
    job.finish("DNS: " & answer.error)
  else:
    job.addresses = answer.addresses
    job.startConnection()

proc pump(queue: HttpDownloadQueue) =
  if queue.pumping or queue.stopped: return
  queue.pumping = true
  try:
    while queue.pending.len > 0 and queue.active.len < queue.maxActive:
      let job = queue.pending.popFirst()
      queue.active[job.id] = job
      if isIpAddress(job.host):
        job.addresses = @[job.host]
        job.startConnection()
      else:
        emit queue.resolveRequested(job.id, job.host)
  finally:
    queue.pumping = false

proc onConnected(job: HttpDownload) {.slot.} =
  if job.done: return
  try:
    let host = if ':' in job.host: "[" & job.host & "]" else: job.host
    let authority = if job.port == Port(80): host else: host & ":" &
        $job.port.uint16
    job.stream.queueWrite("GET " & job.target & " HTTP/1.1\r\nHost: " &
      authority &
      "\r\nConnection: close\r\nAccept-Encoding: identity\r\n\r\n")
  except CatchableError as error:
    job.finish(error.msg)

proc onData(job: HttpDownload, data: string) {.slot.} =
  if job.done: return
  try:
    let chunks = job.parser.add(data)
    if not job.reportedHeaders and job.parser.status != 0:
      job.reportedHeaders = true
      emit job.owner.downloadHeaders(job.id, job.parser.status,
          job.parser.headers)
    for chunk in chunks:
      if not job.done: emit job.owner.downloadData(job.id, chunk)
    if not job.done and job.parser.isDone(): job.finish("")
  except CatchableError as error:
    job.finish(error.msg)

proc onClosed(job: HttpDownload, error: string) {.slot.} =
  if job.done: return
  if error.len > 0:
    if not job.reportedHeaders and job.addressIndex < job.addresses.len:
      job.retryTimer = newSigilTimer(initDuration(milliseconds = 1), count = 1)
      connect(job.retryTimer, timeout, job, onRetry)
      job.retryTimer.start(job.owner.thread.toSigilThread())
    else: job.finish(error)
  else:
    try:
      job.parser.finish()
      job.finish("")
    except CatchableError as failure:
      job.finish(failure.msg)

proc enqueue*(queue: HttpDownloadQueue, url: string): uint64 =
  ## Queue a GET; progress and terminal results are emitted on this scheduler.
  if queue.isNil or queue.stopped: raise newException(IOError, "HTTP queue is closed")
  if queue.pending.len >= queue.maxPending: raise newException(IOError, "HTTP queue is full")
  let parsed = parseUri(url)
  if parsed.scheme.toLowerAscii() != "http":
    raise newException(ValueError, "only plain HTTP URLs are currently supported")
  if parsed.hostname.len == 0 or parsed.username.len > 0 or
      parsed.password.len > 0 or parsed.hostname.contains({'\r', '\n', '\0'}) or
      parsed.path.contains({'\r', '\n', '\0', ' '}) or
      parsed.query.contains({'\r', '\n', '\0', ' '}):
    raise newException(ValueError, "invalid HTTP URL")
  let portNum = if parsed.port.len == 0: 80 else: parseInt(parsed.port)
  if portNum < 1 or portNum > 65535: raise newException(ValueError, "invalid HTTP port")
  var target = if parsed.path.len == 0: "/" else: parsed.path
  if parsed.query.len > 0: target.add("?" & parsed.query)
  queue.nextId += 1
  if queue.nextId == 0: queue.nextId += 1
  result = queue.nextId
  let job = HttpDownload(owner: queue, id: result, host: parsed.hostname,
    port: Port(portNum), target: target, parser: initHttpResponseParser(queue.maxBody))
  queue.pending.addLast(job)
  queue.pump()

proc cancel*(queue: HttpDownloadQueue, id: uint64): bool =
  ## Cancel a queued or active request; emits one terminal result.
  if queue.isNil: return false
  if queue.active.hasKey(id):
    queue.active[id].finish("cancelled")
    return true
  var remaining = initDeque[HttpDownload]()
  var cancelled: HttpDownload
  while queue.pending.len > 0:
    let job = queue.pending.popFirst()
    if job.id == id: cancelled = job
    else: remaining.addLast(job)
  queue.pending = move remaining
  if not cancelled.isNil:
    cancelled.finish("cancelled")
    return true

proc close*(queue: HttpDownloadQueue) =
  ## Cancel all work; the resolver worker remains owned by the caller.
  if queue.isNil or queue.stopped: return
  queue.stopped = true
  while queue.pending.len > 0: queue.pending.popFirst().finish("cancelled")
  var active: seq[HttpDownload]
  for job in queue.active.values: active.add(job)
  for job in active: job.finish("cancelled")
