import std/unittest
import std/os
import sigils
import sigils/threads
import sigils/asyncHttp
import threading/channels

suite "threaded agent proxy":

  test "simple proxy test":
    if false:
      var ap = newAsyncProcessor()
      ap.startThread()

      let httpProxy = newAgentProxy[HttpRequest, HttpResult]()
      echo "initial async http with trigger ",
        " tid: ", getThreadId(), " ", httpProxy[].trigger.repr

      ap.add(newHttpExecutor(httpProxy))
      os.sleep(1_00)

      type HttpHandler = ref object of Agent

      proc receive(ha: HttpHandler, key: AsyncKey, data: HttpResult) {.slot.} =
        echo "got http result: ", data.body

      let handler = HttpHandler.new()

      var hreq = HttpAgent.new(httpProxy)
      hreq.connect(received, handler, receive)
      hreq.send(parseUri "http://first.example.com")

      os.sleep(1_00)
      hreq.send(parseUri "http://neverssl.com")

      os.sleep(1_000)

      ap.finish()
      ap[].thread.joinThread()

      # TODO: need to document that this needs to be tied
      #       into whatever event system / main loop
      httpProxy.poll()
      os.sleep(1_000)