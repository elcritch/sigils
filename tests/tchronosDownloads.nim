when defined(features.sigils.httpChronos):
  import std/[nativesockets, net, os, tables, unittest]
  import sigils
  import sigils/threadChronos
  import sigils/http/chronosDownloads

  type Observer = ref object of Agent
    finished: bool
    status: int
    body, error: string
    completions: Table[uint64, string]

  proc submit(self: Observer, id: uint64, url: string) {.signal.}
  proc cancel(self: Observer, id: uint64) {.signal.}
  proc headers(self: Observer, id: uint64, status: int,
      headers: Table[string, string]) {.slot.} =
    self.status = status
  proc chunk(self: Observer, id: uint64, data: string) {.slot.} =
    self.body.add(data)
  proc recordFinished(self: Observer, id: uint64, error: string) {.slot.} =
    self.completions[id] = error
    self.error = error
    self.finished = true

  proc serve(fd: SocketHandle) {.thread.} =
    var accepted = osInvalidSocket
    for i in 0..<1000:
      accepted = nativesockets.accept(fd)[0]
      if accepted != osInvalidSocket: break
      sleep(2)
    if accepted != osInvalidSocket:
      let client = newSocket(accepted, buffered = false)
      try:
        var data = newString(1024)
        discard client.recv(addr data[0], data.len)
        client.send("HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello")
      finally:
        client.close()

  suite "Chronos downloads":
    test "streams a queued request on a helper thread":
      startLocalThreadDefault()
      let home = getCurrentSigilThread()
      let listener = newSocket(buffered = false)
      listener.bindAddr(Port(0), "127.0.0.1")
      listener.listen()
      listener.getFd().setBlocking(false)
      let port = listener.getLocalAddr()[1]
      var server: Thread[SocketHandle]
      createThread(server, serve, listener.getFd())
      let worker = newSigilChronosThread()
      worker.start()
      block:
        var queue = newChronosDownloadQueue()
        let proxy = queue.moveToThread(worker)
        let observer = Observer()
        connectThreaded(observer, submit, proxy, enqueueChronosDownload)
        connectThreaded(proxy, chronosDownloadHeaders, observer,
            Observer.headers())
        connectThreaded(proxy, chronosDownloadData, observer, Observer.chunk())
        connectThreaded(proxy, chronosDownloadFinished, observer,
            Observer.recordFinished())
        emit observer.submit(1, "http://127.0.0.1:" & $port.uint16 & "/")
        for i in 0..<1500:
          discard home.poll(NonBlocking)
          if observer.finished: break
          sleep(2)
        check observer.finished
        check observer.error == ""
        check observer.status == 200
        check observer.body == "hello"
      worker.stop()
      worker.join()
      server.joinThread()
      listener.close()

    test "reports a response exceeding the body limit":
      startLocalThreadDefault()
      let home = getCurrentSigilThread()
      let listener = newSocket(buffered = false)
      listener.bindAddr(Port(0), "127.0.0.1")
      listener.listen()
      listener.getFd().setBlocking(false)
      let port = listener.getLocalAddr()[1]
      var server: Thread[SocketHandle]
      createThread(server, serve, listener.getFd())
      let worker = newSigilChronosThread()
      worker.start()
      block:
        var queue = newChronosDownloadQueue(maxBody = 3)
        let proxy = queue.moveToThread(worker)
        let observer = Observer()
        connectThreaded(observer, submit, proxy, enqueueChronosDownload)
        connectThreaded(proxy, chronosDownloadHeaders, observer,
            Observer.headers())
        connectThreaded(proxy, chronosDownloadData, observer, Observer.chunk())
        connectThreaded(proxy, chronosDownloadFinished, observer,
            Observer.recordFinished())
        emit observer.submit(1, "http://127.0.0.1:" & $port.uint16 & "/")
        for i in 0..<1500:
          discard home.poll(NonBlocking)
          if observer.finished: break
          sleep(2)
        check observer.finished
        check observer.error == "HTTP response exceeds body limit"
        check observer.status == 200
        check observer.body.len <= 3
      worker.stop()
      worker.join()
      server.joinThread()
      listener.close()

    test "cancels active and pending requests":
      startLocalThreadDefault()
      let home = getCurrentSigilThread()
      let listener = newSocket(buffered = false)
      listener.bindAddr(Port(0), "127.0.0.1")
      listener.listen()
      let port = listener.getLocalAddr()[1]
      let worker = newSigilChronosThread()
      worker.start()
      block:
        var queue = newChronosDownloadQueue(maxActive = 1)
        let proxy = queue.moveToThread(worker)
        let observer = Observer(completions: initTable[uint64, string]())
        connectThreaded(observer, submit, proxy, enqueueChronosDownload)
        connectThreaded(observer, cancel, proxy, cancelChronosDownload)
        connectThreaded(proxy, chronosDownloadFinished, observer,
            Observer.recordFinished())
        let url = "http://127.0.0.1:" & $port.uint16 & "/"
        emit observer.submit(1, url)
        emit observer.submit(2, url)
        emit observer.cancel(2)
        emit observer.cancel(1)
        for i in 0..<500:
          discard home.poll(NonBlocking)
          if observer.completions.len == 2: break
          sleep(2)
        check observer.completions.len == 2
        check observer.completions.getOrDefault(1) == "cancelled"
        check observer.completions.getOrDefault(2) == "cancelled"
      listener.close()
      worker.stop()
      worker.join()
