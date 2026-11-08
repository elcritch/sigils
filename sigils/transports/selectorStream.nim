## Nonblocking TCP streams owned by a Sigils selector scheduler.
## All operations and signals must run on the owning scheduler thread.

import std/[net, nativesockets, os, selectors, times]
import ../[agents, core, threadSelectors]

type
  SelectorStream* = ref object of Agent
    thread: SigilSelectorThreadPtr
    socket: Socket
    event: SigilSocketEvent
    output: string
    maxQueuedBytes: int
    connecting: bool
    deadline: SigilTimer
    readPaused: bool
    closing: bool
    closed: bool

  SelectorListener* = ref object of Agent
    thread: SigilSelectorThreadPtr
    socket: Socket
    event: SigilSocketEvent
    maxQueuedBytes: int
    closed: bool

proc streamConnected*(stream: SelectorStream) {.signal.}
proc streamData*(stream: SelectorStream, data: string) {.signal.}
proc streamDrained*(stream: SelectorStream) {.signal.}
proc streamClosed*(stream: SelectorStream, error: string) {.signal.}
proc streamAccepted*(listener: SelectorListener,
    stream: SelectorStream) {.signal.}
proc listenerClosed*(listener: SelectorListener, error: string) {.signal.}

proc streamReady(stream: SelectorStream, fd: int, events: set[Event]) {.slot.}
proc listenerReady(listener: SelectorListener, fd: int, events: set[
    Event]) {.slot.}
proc deadlineExpired(stream: SelectorStream) {.slot.}

proc wouldBlock(error: int32): bool =
  when defined(windows):
    error == WSAEWOULDBLOCK
  else:
    error == EAGAIN or error == EWOULDBLOCK

proc inProgress(error: int32): bool =
  when defined(windows):
    error == WSAEWOULDBLOCK or error == WSAEINPROGRESS
  else:
    error == EINPROGRESS or error == EINTR or wouldBlock(error)

proc closeWithError(stream: SelectorStream, error: string) =
  if stream.isNil or stream.closed:
    return
  stream.closed = true
  if not stream.deadline.isNil:
    stream.deadline.cancel(stream.thread.toSigilThread())
    stream.deadline = nil
  stream.event.unregister(stream.thread)
  stream.socket.close()
  stream.output.setLen(0)
  emit stream.streamClosed(error)

proc close*(stream: SelectorStream) =
  ## Close immediately; pending output is discarded. Emits streamClosed once.
  stream.closeWithError("")

proc abort*(stream: SelectorStream, error: string) =
  ## Close immediately and report a protocol or application failure.
  stream.closeWithError(error)

proc isClosed*(stream: SelectorStream): bool =
  stream.isNil or stream.closed

proc updateEvents(stream: SelectorStream) =
  if not stream.closed:
    var events: set[Event]
    if not stream.readPaused:
      events.incl(Event.Read)
    if stream.connecting or stream.output.len > 0:
      events.incl(Event.Write)
    if stream.event.events != events:
      stream.event.setEvents(stream.thread, events)

proc flush(stream: SelectorStream) =
  if stream.closed or stream.connecting or stream.output.len == 0:
    return
  let written = stream.socket.send(unsafeAddr stream.output[0],
      stream.output.len)
  if written > 0:
    if written == stream.output.len:
      stream.output.setLen(0)
      stream.updateEvents()
      emit stream.streamDrained()
      if not stream.closed and stream.closing:
        stream.closeWithError("")
    else:
      stream.output = stream.output[written..^1]
  elif written < 0:
    let error = osLastError()
    if not wouldBlock(error.int32):
      stream.closeWithError(osErrorMsg(error))
  if not stream.closed:
    stream.updateEvents()

proc queueWrite*(stream: SelectorStream, data: string) =
  ## Queue bytes for writing; raises if closed or the output limit is exceeded.
  if stream.isClosed() or stream.closing:
    raise newException(IOError, "stream is closing or closed")
  if data.len > stream.maxQueuedBytes - stream.output.len:
    raise newException(IOError, "stream output queue is full")
  stream.output.add(data)
  stream.updateEvents()

proc clearDeadline*(stream: SelectorStream) =
  ## Cancel the current deadline, if any.
  if not stream.isNil and not stream.deadline.isNil:
    stream.deadline.cancel(stream.thread.toSigilThread())
    stream.deadline = nil

proc setDeadline*(stream: SelectorStream, milliseconds: Positive) =
  ## Close the stream with a timeout error after this many milliseconds.
  if stream.isClosed():
    raise newException(IOError, "stream is closed")
  stream.clearDeadline()
  let timer = newSigilTimer(initDuration(milliseconds = milliseconds), count = 1)
  connect(timer, timeout, stream, deadlineExpired)
  timer.start(stream.thread.toSigilThread())
  stream.deadline = timer

proc deadlineExpired(stream: SelectorStream) {.slot.} =
  stream.deadline = nil
  stream.closeWithError("stream deadline exceeded")

proc pauseRead*(stream: SelectorStream) =
  ## Stop receiving until resumeRead is called. Buffered OS data is retained.
  if stream.isClosed():
    raise newException(IOError, "stream is closed")
  stream.readPaused = true
  stream.updateEvents()

proc resumeRead*(stream: SelectorStream) =
  ## Resume receiving data on the owning selector thread.
  if stream.isClosed():
    raise newException(IOError, "stream is closed")
  stream.readPaused = false
  stream.updateEvents()

proc closeAfterFlush*(stream: SelectorStream) =
  ## Reject new writes and close when all queued bytes have been sent.
  if stream.isClosed() or stream.closing:
    return
  stream.closing = true
  if stream.output.len == 0:
    stream.closeWithError("")

proc queuedBytes*(stream: SelectorStream): int =
  if stream.isNil: 0 else: stream.output.len

proc newStream(thread: SigilSelectorThreadPtr, socket: Socket,
    maxQueuedBytes: int, connecting: bool): SelectorStream =
  result = SelectorStream(thread: thread, socket: socket,
    maxQueuedBytes: maxQueuedBytes, connecting: connecting)
  result.event = newSigilSocketEvent(thread, socket,
    if connecting: {Event.Read, Event.Write} else: {Event.Read})
  connect(result.event, socketReady, result, streamReady)

proc streamReady(stream: SelectorStream, fd: int, events: set[Event]) {.slot.} =
  if stream.closed:
    return
  if stream.connecting and (Event.Write in events or Event.Error in events):
    let error = getSockOptInt(stream.socket.getFd(), SOL_SOCKET, SO_ERROR)
    if error != 0:
      stream.closeWithError(osErrorMsg(OSErrorCode(error)))
      return
    stream.connecting = false
    stream.updateEvents()
    emit stream.streamConnected()
    if stream.closed:
      return
  if Event.Read in events and not stream.readPaused:
    var data = newString(16 * 1024)
    let count = stream.socket.recv(addr data[0], data.len)
    if count > 0:
      data.setLen(count)
      emit stream.streamData(data)
    elif count == 0:
      stream.closeWithError("")
      return
    else:
      let error = osLastError()
      if not wouldBlock(error.int32):
        stream.closeWithError(osErrorMsg(error))
        return
  if not stream.closed and Event.Write in events:
    stream.flush()
  if not stream.closed and Event.Error in events:
    let error = getSockOptInt(stream.socket.getFd(), SOL_SOCKET, SO_ERROR)
    stream.closeWithError(if error == 0: "socket error" else: osErrorMsg(
        OSErrorCode(error)))

proc connectTcp*(thread: SigilSelectorThreadPtr, address: string, port: Port,
    maxQueuedBytes = 1024 * 1024): SelectorStream =
  ## Start a connection to a numeric IPv4 or IPv6 address; no DNS is performed.
  ## Completion is reported by streamConnected or streamClosed.
  if thread.isNil or maxQueuedBytes <= 0 or not isIpAddress(address):
    raise newException(ValueError, "expected a selector, IP address and positive queue limit")
  let domain = if parseIpAddress(address).family ==
      IpAddressFamily.IPv6: AF_INET6 else: AF_INET
  let socket = newSocket(domain = domain, sockType = SOCK_STREAM,
    protocol = IPPROTO_TCP, buffered = false)
  try:
    socket.getFd().setBlocking(false)
    var addresses = getAddrInfo(address, port, domain, SOCK_STREAM, IPPROTO_TCP)
    try:
      let status = nativesockets.connect(socket.getFd(), addresses.ai_addr,
        addresses.ai_addrlen.SockLen)
      if status != 0:
        let error = osLastError()
        if not inProgress(error.int32):
          raiseOSError(error)
    finally:
      freeAddrInfo(addresses)
    result = newStream(thread, socket, maxQueuedBytes, true)
  except:
    socket.close()
    raise

proc closeWithError(listener: SelectorListener, error: string) =
  if listener.isNil or listener.closed:
    return
  listener.closed = true
  listener.event.unregister(listener.thread)
  listener.socket.close()
  emit listener.listenerClosed(error)

proc close*(listener: SelectorListener) =
  ## Stop accepting; previously accepted streams remain open.
  listener.closeWithError("")

proc localAddress*(listener: SelectorListener): tuple[host: string, port: Port] =
  if listener.isNil or listener.closed:
    raise newException(IOError, "listener is closed")
  listener.socket.getLocalAddr()

proc listenerReady(listener: SelectorListener, fd: int, events: set[
    Event]) {.slot.} =
  if listener.closed:
    return
  if Event.Error in events:
    listener.closeWithError("listener socket error")
    return
  if Event.Read in events:
    var socket: owned(Socket)
    try:
      listener.socket.accept(socket)
      socket.getFd().setBlocking(false)
      let stream = newStream(listener.thread, socket, listener.maxQueuedBytes, false)
      emit listener.streamAccepted(stream)
    except OSError as error:
      if not wouldBlock(error.errorCode):
        listener.closeWithError(error.msg)

proc listenTcp*(thread: SigilSelectorThreadPtr, host = "127.0.0.1",
    port = Port(0), maxQueuedBytes = 1024 * 1024): SelectorListener =
  ## Listen on an IPv4 or IPv6 interface. Accepted streams are owned by the receiver.
  if thread.isNil or maxQueuedBytes <= 0:
    raise newException(ValueError, "expected a selector and positive queue limit")
  let domain = if isIpAddress(host) and parseIpAddress(host).family ==
      IpAddressFamily.IPv6:
    AF_INET6
  else:
    AF_INET
  let socket = newSocket(domain = domain, sockType = SOCK_STREAM,
    protocol = IPPROTO_TCP, buffered = false)
  try:
    socket.setSockOpt(OptReuseAddr, true)
    socket.getFd().setBlocking(false)
    socket.bindAddr(port, host)
    socket.listen()
    result = SelectorListener(thread: thread, socket: socket,
        maxQueuedBytes: maxQueuedBytes)
    result.event = newSigilSocketEvent(thread, socket)
    connect(result.event, socketReady, result, listenerReady)
  except:
    socket.close()
    raise

when defined(posix):
  proc connectUnix*(thread: SigilSelectorThreadPtr, path: string,
      maxQueuedBytes = 1024 * 1024): SelectorStream =
    ## Connect to a Unix-domain socket without blocking the selector.
    if thread.isNil or path.len == 0 or '\0' in path or maxQueuedBytes <= 0:
      raise newException(ValueError, "expected a selector, socket path and positive queue limit")
    let socket = newSocket(domain = AF_UNIX, sockType = SOCK_STREAM,
      protocol = IPPROTO_NONE, buffered = false)
    try:
      socket.getFd().setBlocking(false)
      try:
        socket.connectUnix(path)
      except OSError as error:
        if not inProgress(error.errorCode):
          raise
      result = newStream(thread, socket, maxQueuedBytes, true)
    except:
      socket.close()
      raise

  proc listenUnix*(thread: SigilSelectorThreadPtr, path: string,
      maxQueuedBytes = 1024 * 1024): SelectorListener =
    ## Bind a Unix socket. The caller owns removal of the socket path.
    if thread.isNil or path.len == 0 or '\0' in path or maxQueuedBytes <= 0:
      raise newException(ValueError, "expected a selector, socket path and positive queue limit")
    let socket = newSocket(domain = AF_UNIX, sockType = SOCK_STREAM,
      protocol = IPPROTO_NONE, buffered = false)
    try:
      socket.getFd().setBlocking(false)
      socket.bindUnix(path)
      socket.listen()
      result = SelectorListener(thread: thread, socket: socket,
        maxQueuedBytes: maxQueuedBytes)
      result.event = newSigilSocketEvent(thread, socket)
      connect(result.event, socketReady, result, listenerReady)
    except:
      socket.close()
      raise
