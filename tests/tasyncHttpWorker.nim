import std/[asyncdispatch, httpclient, nativesockets, net, os, unittest]
import sigils
import sigils/threadAsyncs

type
  HttpWorker = ref object of AgentActor
  HttpObserver = ref object of Agent
    finished: bool
    body, error: string

proc fetched(self: HttpWorker, body, error: string) {.signal.}
proc requestFetch(self: HttpObserver, url: string) {.signal.}

proc fetch(self: HttpWorker, url: string) {.async.} =
  let client = newAsyncHttpClient()
  try:
    let body = await client.getContent(url)
    emit self.fetched(body, "")
  except CatchableError as error:
    emit self.fetched("", error.msg)
  finally:
    client.close()

proc startFetch(self: HttpWorker, url: string) {.slot.} =
  asyncCheck self.fetch(url)

proc done(self: HttpObserver, body, error: string) {.slot.} =
  self.body = body
  self.error = error
  self.finished = true

proc serve(fd: SocketHandle) {.thread.} =
  var accepted = osInvalidSocket
  for i in 0..<1000:
    accepted = nativesockets.accept(fd)[0]
    if accepted != osInvalidSocket:
      break
    sleep(2)
  if accepted != osInvalidSocket:
    let client = newSocket(accepted, buffered = false)
    try:
      var data = newString(1024)
      discard client.recv(addr data[0], data.len)
      client.send("HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello")
    finally:
      client.close()

suite "async HTTP on Sigils worker":
  test "runs stdlib client and delivers its result":
    startLocalThreadDefault()
    let home = getCurrentSigilThread()
    let listener = newSocket(buffered = false)
    listener.setSockOpt(OptReuseAddr, true)
    listener.bindAddr(Port(0), "127.0.0.1")
    listener.listen()
    listener.getFd().setBlocking(false)
    let port = listener.getLocalAddr()[1]
    var server: Thread[SocketHandle]
    createThread(server, serve, listener.getFd())
    let worker = newSigilAsyncThread()
    worker.start()
    block:
      var client = HttpWorker()
      let proxy = client.moveToThread(worker)
      let observer = HttpObserver()
      connectThreaded(proxy, fetched, observer, HttpObserver.done())
      connectThreaded(observer, requestFetch, proxy, startFetch)
      emit observer.requestFetch("http://127.0.0.1:" & $port.uint16 & "/")
      for i in 0..<1500:
        discard home.poll(NonBlocking)
        if observer.finished: break
        sleep(2)
      check observer.finished
      check observer.error == ""
      check observer.body == "hello"
    worker.stop()
    worker.join()
    server.joinThread()
    listener.close()
