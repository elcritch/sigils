when defined(features.sigils.httpSelector):
  import std/[net, tables, unittest]
  import sigils
  import sigils/threadSelectors
  import sigils/transports/selectorStream
  import sigils/http/downloads

  type Observer = ref object of Agent
    server: seq[SelectorStream]
    data: string
    status: int
    finished: int
    error: string

  proc accepted(self: Observer, stream: SelectorStream) {.slot.} =
    self.server.add(stream)
    stream.queueWrite("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello")

  proc headers(self: Observer, id: uint64, status: int,
      headers: Table[string, string]) {.slot.} =
    self.status = status

  proc data(self: Observer, id: uint64, data: string) {.slot.} =
    self.data.add(data)

  proc finished(self: Observer, id: uint64, error: string) {.slot.} =
    self.finished.inc()
    self.error = error

  suite "HTTP downloads":
    test "streams a response from a numeric address":
      let thread = newSigilSelectorThread()
      setLocalSigilThread(thread)
      block:
        let observer = Observer()
        let listener = listenTcp(thread)
        connect(listener, streamAccepted, observer, accepted)
        let queue = newHttpDownloadQueue(thread)
        expect ValueError:
          discard queue.enqueue("http://localhost/")
        connect(queue, downloadHeaders, observer, headers)
        connect(queue, downloadData, observer, data)
        connect(queue, downloadFinished, observer, finished)
        discard queue.enqueue("http://127.0.0.1:" & $listener.localAddress().port.uint16 & "/")
        for i in 0..<1000:
          discard thread.poll()
          if observer.finished > 0: break
        check observer.finished == 1
        check observer.error == ""
        check observer.status == 200
        check observer.data == "hello"
        queue.close()
        for stream in observer.server: stream.close()
        listener.close()
      thread.closeSelectorThread()

    test "streams a response over IPv6 loopback":
      let thread = newSigilSelectorThread()
      setLocalSigilThread(thread)
      block:
        let observer = Observer()
        let listener = listenTcp(thread, host = "::1")
        connect(listener, streamAccepted, observer, accepted)
        let queue = newHttpDownloadQueue(thread)
        connect(queue, downloadHeaders, observer, headers)
        connect(queue, downloadData, observer, data)
        connect(queue, downloadFinished, observer, finished)
        discard queue.enqueue("http://[::1]:" & $listener.localAddress().port.uint16 & "/")
        for i in 0..<1000:
          discard thread.poll()
          if observer.finished > 0: break
        check observer.finished == 1
        check observer.error == ""
        check observer.status == 200
        check observer.data == "hello"
        queue.close()
        for stream in observer.server: stream.close()
        listener.close()
      thread.closeSelectorThread()

    test "cancels pending and active requests once":
      let thread = newSigilSelectorThread()
      setLocalSigilThread(thread)
      block:
        let queue = newHttpDownloadQueue(thread, maxActive = 1)
        let observer = Observer()
        connect(queue, downloadFinished, observer, finished)
        let first = queue.enqueue("http://127.0.0.1:1/")
        let second = queue.enqueue("http://127.0.0.1:1/")
        check queue.cancel(second)
        check observer.finished == 1
        check observer.error == "cancelled"
        check queue.cancel(first)
        check observer.finished == 2
        check not queue.cancel(first)
        queue.close()
      thread.closeSelectorThread()
