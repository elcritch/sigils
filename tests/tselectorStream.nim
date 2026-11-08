import std/[net, unittest]
import sigils
import sigils/threadSelectors
import sigils/transports/selectorStream

type Observer = ref object of Agent
  accepted: SelectorStream
  connected: bool
  received: string
  closed: int
  error: string

proc onData(self: Observer, data: string) {.slot.} =
  self.received.add(data)

proc onAccepted(self: Observer, stream: SelectorStream) {.slot.} =
  self.accepted = stream
  connect(stream, streamData, self, onData)

proc onConnected(self: Observer) {.slot.} =
  self.connected = true

proc onClosed(self: Observer, error: string) {.slot.} =
  self.closed.inc()
  self.error = error

suite "selector streams":
  test "connect, transfer, enforce queue bounds, and close":
    let thread = newSigilSelectorThread()
    setLocalSigilThread(thread)
    let listener = listenTcp(thread, maxQueuedBytes = 8)
    let observer = Observer()
    connect(listener, streamAccepted, observer, onAccepted)
    let client = connectTcp(thread, "127.0.0.1", listener.localAddress().port,
      maxQueuedBytes = 8)
    connect(client, streamConnected, observer, onConnected)
    connect(client, streamClosed, observer, onClosed)
    client.queueWrite("hello")
    expect IOError:
      client.queueWrite("1234")
    for i in 0..<200:
      discard thread.poll()
      if observer.received == "hello":
        break
    check observer.connected
    check observer.received == "hello"
    check client.queuedBytes == 0
    client.close()
    client.close()
    check observer.closed == 1
    if not observer.accepted.isNil:
      observer.accepted.close()
    listener.close()
    thread.closeSelectorThread()

when defined(posix):
  import std/os

  suite "Unix selector streams":
    test "transfer data over a local socket":
      let path = getTempDir() / ("sigils-stream-" & $getCurrentProcessId() & ".sock")
      let thread = newSigilSelectorThread()
      setLocalSigilThread(thread)
      let listener = listenUnix(thread, path)
      let observer = Observer()
      connect(listener, streamAccepted, observer, onAccepted)
      let client = connectUnix(thread, path)
      connect(client, streamConnected, observer, onConnected)
      client.queueWrite("local")
      for i in 0..<200:
        discard thread.poll()
        if observer.received == "local":
          break
      check observer.connected
      check observer.received == "local"
      client.close()
      if not observer.accepted.isNil:
        observer.accepted.close()
      listener.close()
      thread.closeSelectorThread()
      removeFile(path)

suite "IPv6 selector streams":
  test "connect and transfer over IPv6 loopback":
    let thread = newSigilSelectorThread()
    setLocalSigilThread(thread)
    let listener = listenTcp(thread, host = "::1")
    let observer = Observer()
    connect(listener, streamAccepted, observer, onAccepted)
    let client = connectTcp(thread, "::1", listener.localAddress().port)
    connect(client, streamConnected, observer, onConnected)
    client.queueWrite("ipv6")
    for i in 0..<200:
      discard thread.poll()
      if observer.received == "ipv6":
        break
    check observer.connected
    check observer.received == "ipv6"
    client.close()
    if not observer.accepted.isNil:
      observer.accepted.close()
    listener.close()
    thread.closeSelectorThread()

suite "selector stream lifecycle":
  test "pauses reads and gracefully flushes before closing":
    let thread = newSigilSelectorThread()
    setLocalSigilThread(thread)
    let listener = listenTcp(thread)
    let observer = Observer()
    connect(listener, streamAccepted, observer, onAccepted)
    let client = connectTcp(thread, "127.0.0.1", listener.localAddress().port)
    connect(client, streamClosed, observer, onClosed)
    for i in 0..<200:
      discard thread.poll()
      if not observer.accepted.isNil:
        break
    require not observer.accepted.isNil
    observer.accepted.pauseRead()
    client.queueWrite("queued data")
    client.closeAfterFlush()
    expect IOError:
      client.queueWrite("late")
    for i in 0..<100:
      discard thread.poll()
      if client.isClosed(): break
    check client.isClosed()
    check observer.closed == 1
    check observer.received == ""
    observer.accepted.resumeRead()
    for i in 0..<200:
      discard thread.poll()
      if observer.received == "queued data": break
    check observer.received == "queued data"
    observer.accepted.close()
    listener.close()
    thread.closeSelectorThread()

  test "deadline closes once and can be cancelled":
    let thread = newSigilSelectorThread()
    setLocalSigilThread(thread)
    let listener = listenTcp(thread)
    let observer = Observer()
    connect(listener, streamAccepted, observer, onAccepted)
    let client = connectTcp(thread, "127.0.0.1", listener.localAddress().port)
    connect(client, streamClosed, observer, onClosed)
    client.setDeadline(1)
    client.clearDeadline()
    for i in 0..<20:
      discard thread.poll()
    check not client.isClosed()
    client.setDeadline(2)
    for i in 0..<200:
      discard thread.poll()
      if client.isClosed(): break
    check client.isClosed()
    check observer.closed == 1
    check observer.error == "stream deadline exceeded"
    client.close()
    check observer.closed == 1
    if not observer.accepted.isNil:
      observer.accepted.close()
    listener.close()
    thread.closeSelectorThread()
