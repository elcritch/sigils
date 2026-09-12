import std/[json, net, parseutils, strutils, unittest]

import sigils
import sigils/threadChronos
import sigils/rpcs/jsonrpc
import sigils/rpcs/json/[jrAgents, jrChronos]

type AddArgs = tuple[left: int, right: int]

let addNumbers = selector[AddArgs, int]("addNumbers")

proc addImpl(self: DynamicAgent, args: AddArgs): int =
  args.left + args.right

proc splitAddress(address: string): tuple[host: string, port: Port] =
  let separator = address.rfind(':')
  check separator > 0
  var port: int
  check parseInt(address, port, separator + 1) > 0
  (address[0..<separator], Port(port))

suite "JSON-RPC Chronos helper thread":
  test "returns protocol dispatch to the application thread":
    startLocalThreadDefault()
    let
      home = getCurrentSigilThread()
      helper = newSigilChronosThread()
      calculator = DynamicAgent()
      adapter = newJsonRpcAdapter()
      dispatcher = newJsonRpcDispatcher(adapter)

    discard calculator.addMethod(addNumbers, toDynamicMethod(addImpl))
    adapter.registerSelector("calculator", calculator, addNumbers)

    block ioLifetime:
      var io = newJsonRpcChronosIo()
      let proxy = io.moveToThread(helper)
      dispatcher.connectJsonRpc(proxy)
      helper.start()
      emit dispatcher.jsonRpcStartRequested()
      while not dispatcher.isListening:
        discard home.poll()

      let remote = splitAddress(dispatcher.boundAddress)
      let socket = newSocket(buffered = false)
      try:
        socket.connect(remote.host, remote.port)
        socket.send(
          """{"jsonrpc":"2.0","method":"calculator.addNumbers","params":[9,8],"id":"chronos"}
"""
        )
        discard home.poll()
        let reply = parseJson(socket.recvLine(timeout = 2_000))
        check reply["result"].getInt() == 17
        check reply["id"].getStr() == "chronos"
      finally:
        socket.close()

      emit dispatcher.jsonRpcStopRequested()
      while dispatcher.isListening:
        discard home.poll()

    helper.stop()
    helper.join()
