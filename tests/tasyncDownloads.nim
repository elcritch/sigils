import std/[nativesockets, net, os, strutils, tables, unittest]
import sigils
import sigils/threadAsyncs
import sigils/http/asyncDownloads

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

proc serveResponse(fd: SocketHandle, response: string) =
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
      client.send(response)
    finally:
      client.close()

proc serve(fd: SocketHandle) {.thread.} =
  serveResponse(fd, "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello")

proc serveBadStatus(fd: SocketHandle) {.thread.} =
  serveResponse(fd, "HTTP/1.1 700 Nope\r\nContent-Length: 0\r\n\r\n")

proc serveLargeRedirect(fd: SocketHandle) {.thread.} =
  serveResponse(fd, "HTTP/1.1 302 Found\r\nLocation: /final\r\n" &
    "Content-Length: 5\r\nConnection: close\r\n\r\nhello")

proc serveRedirect(fd: SocketHandle) {.thread.} =
  serveResponse(fd, "HTTP/1.1 302 Found\r\nLocation: /final\r\n" &
    "Content-Length: 1\r\nConnection: close\r\n\r\nx")
  serve(fd)

proc runRedirect(serverProc: proc(fd: SocketHandle) {.thread.}, maxBody: int):
    tuple[finished: bool, status: int, body, error: string] =
  startLocalThreadDefault()
  let home = getCurrentSigilThread()
  let listener = newSocket(buffered = false)
  listener.bindAddr(Port(0), "127.0.0.1")
  listener.listen()
  listener.getFd().setBlocking(false)
  let port = listener.getLocalAddr()[1]
  var server: Thread[SocketHandle]
  createThread(server, serverProc, listener.getFd())
  let worker = newSigilAsyncThread()
  worker.start()
  block:
    var queue = newAsyncDownloadQueue(maxBody = maxBody)
    let proxy = queue.moveToThread(worker)
    let observer = Observer()
    connectThreaded(observer, submit, proxy, enqueueAsyncDownload)
    connectThreaded(proxy, asyncDownloadHeaders, observer, Observer.headers())
    connectThreaded(proxy, asyncDownloadData, observer, Observer.chunk())
    connectThreaded(proxy, asyncDownloadFinished, observer,
        Observer.recordFinished())
    emit observer.submit(1, "http://127.0.0.1:" & $port.uint16 & "/")
    for i in 0..<1500:
      discard home.poll(NonBlocking)
      if observer.finished: break
      sleep(2)
    result = (observer.finished, observer.status, observer.body, observer.error)
  worker.stop()
  worker.join()
  server.joinThread()
  listener.close()

suite "stdlib async downloads":
  test "rejects URLs containing newlines":
    let queue = newAsyncDownloadQueue()
    let observer = Observer()
    connect(queue, asyncDownloadFinished, observer, recordFinished)
    queue.enqueueAsyncDownload(1, "http://127.0.0.1/\r\n")
    check observer.finished
    check observer.error == "invalid or duplicate download request"

  test "bounds redirect bodies before following":
    let response = runRedirect(serveLargeRedirect, maxBody = 3)
    check response.finished
    check response.status == 0
    check response.body == ""
    check response.error == "HTTP response exceeds body limit"

  test "follows a bounded relative redirect":
    let response = runRedirect(serveRedirect, maxBody = 5)
    check response.finished
    check response.status == 200
    check response.body == "hello"
    check response.error == ""

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
    let worker = newSigilAsyncThread()
    worker.start()
    block:
      var queue = newAsyncDownloadQueue()
      let proxy = queue.moveToThread(worker)
      let observer = Observer()
      connectThreaded(observer, submit, proxy, enqueueAsyncDownload)
      connectThreaded(proxy, asyncDownloadHeaders, observer, Observer.headers())
      connectThreaded(proxy, asyncDownloadData, observer, Observer.chunk())
      connectThreaded(proxy, asyncDownloadFinished, observer,
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
    let worker = newSigilAsyncThread()
    worker.start()
    block:
      var queue = newAsyncDownloadQueue(maxBody = 3)
      let proxy = queue.moveToThread(worker)
      let observer = Observer()
      connectThreaded(observer, submit, proxy, enqueueAsyncDownload)
      connectThreaded(proxy, asyncDownloadHeaders, observer, Observer.headers())
      connectThreaded(proxy, asyncDownloadData, observer, Observer.chunk())
      connectThreaded(proxy, asyncDownloadFinished, observer,
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

  test "reports a malformed status without crashing the worker":
    startLocalThreadDefault()
    let home = getCurrentSigilThread()
    let listener = newSocket(buffered = false)
    listener.bindAddr(Port(0), "127.0.0.1")
    listener.listen()
    listener.getFd().setBlocking(false)
    let port = listener.getLocalAddr()[1]
    var server: Thread[SocketHandle]
    createThread(server, serveBadStatus, listener.getFd())
    let worker = newSigilAsyncThread()
    worker.start()
    block:
      var queue = newAsyncDownloadQueue()
      let proxy = queue.moveToThread(worker)
      let observer = Observer()
      connectThreaded(observer, submit, proxy, enqueueAsyncDownload)
      connectThreaded(proxy, asyncDownloadFinished, observer,
          Observer.recordFinished())
      emit observer.submit(1, "http://127.0.0.1:" & $port.uint16 & "/")
      for i in 0..<1500:
        discard home.poll(NonBlocking)
        if observer.finished: break
        sleep(2)
      check observer.finished
      check observer.error.startsWith("invalid HTTP response status")
      check observer.status == 0
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
    let worker = newSigilAsyncThread()
    worker.start()
    block:
      var queue = newAsyncDownloadQueue(maxActive = 1)
      let proxy = queue.moveToThread(worker)
      let observer = Observer(completions: initTable[uint64, string]())
      connectThreaded(observer, submit, proxy, enqueueAsyncDownload)
      connectThreaded(observer, cancel, proxy, cancelAsyncDownload)
      connectThreaded(proxy, asyncDownloadFinished, observer,
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
