import std/[json, net, options, parseutils, strutils, unittest]

import sigils
import sigils/threadSelectors
import sigils/rpcs/json/[jsonrpc, jsonrpcAgents, jsonrpcSelector]

type
  Counter = ref object of Agent
    value: int

  CounterSource = ref object of Agent

  AddArgs = tuple[left: int, right: int]

proc setValue(self: Counter, value: int) {.slot.} =
  self.value = value

proc valueChanged(self: CounterSource, value: int) {.signal.}

let addNumbers = selector[AddArgs, int]("addNumbers")
let currentAnswer = selector[tuple[], int]("currentAnswer")

proc addImpl(self: DynamicAgent, args: AddArgs): int =
  args.left + args.right

proc answerImpl(self: DynamicAgent, args: tuple[]): int =
  42

proc response(adapter: JsonRpcAdapter, request: string): JsonNode =
  let encoded = adapter.handleJsonRpc(request)
  check encoded.isSome()
  parseJson(encoded.get())

proc initAdapter(
    counter: Counter,
    sink: Counter,
): JsonRpcAdapter =
  let
    source = CounterSource()
    calculator = DynamicAgent()
  discard calculator.addMethod(addNumbers, toDynamicMethod(addImpl))
  discard calculator.addMethod(currentAnswer, toDynamicMethod(answerImpl))
  let calculatorProtocol = initProtocol(
    "Calculator",
    [requirement(addNumbers), requirement(currentAnswer)],
  )

  result = newJsonRpcAdapter()
  result.registerProtocol("calculator", calculator, calculatorProtocol)
  result.registerSlot("counter", "setValue", counter, Counter.setValue())
  result.registerSignal("events", source, toSigilName("valueChanged"))
  connect(source, valueChanged, sink, setValue)

proc splitAddress(address: string): tuple[host: string, port: Port] =
  let separator = address.rfind(':')
  check separator > 0
  var port: int
  check parseInt(address, port, separator + 1) > 0
  (address[0..<separator], Port(port))

suite "JSON-RPC protocol adapter":
  test "protocol selectors accept named and positional parameters":
    let
      counter = Counter()
      sink = Counter()
      adapter = initAdapter(counter, sink)

    let named = adapter.response(
      """{"jsonrpc":"2.0","method":"calculator.addNumbers","params":{"left":20,"right":22},"id":"named"}"""
    )
    check named["result"].getInt() == 42
    check named["id"].getStr() == "named"

    let positional = adapter.response(
      """{"jsonrpc":"2.0","method":"calculator.addNumbers","params":[7,8],"id":2}"""
    )
    check positional["result"].getInt() == 15
    check positional["id"].getInt() == 2

  test "omitted parameters invoke a zero-argument selector":
    let adapter = initAdapter(Counter(), Counter())
    let reply = adapter.response(
      """{"jsonrpc":"2.0","method":"calculator.currentAnswer","id":1}"""
    )
    check reply["result"].getInt() == 42

  test "slots return acknowledgements and notifications return nothing":
    let
      counter = Counter()
      sink = Counter()
      adapter = initAdapter(counter, sink)

    let slotReply = adapter.response(
      """{"jsonrpc":"2.0","method":"counter.setValue","params":[71],"id":3}"""
    )
    check slotReply["result"].getBool()
    check counter.value == 71

    let selectorNotification = adapter.handleJsonRpc(
      """{"jsonrpc":"2.0","method":"calculator.addNumbers","params":[1,2]}"""
    )
    check selectorNotification.isNone()

    let signalNotification = adapter.handleJsonRpc(
      """{"jsonrpc":"2.0","method":"events.valueChanged","params":[99]}"""
    )
    check signalNotification.isNone()
    check sink.value == 99

  test "standard errors preserve valid request ids":
    let adapter = initAdapter(Counter(), Counter())

    let missing = adapter.response(
      """{"jsonrpc":"2.0","method":"calculator.missing","id":"missing"}"""
    )
    check missing["error"]["code"].getInt() == RpcMethodNotFound
    check missing["id"].getStr() == "missing"

    let invalidParams = adapter.response(
      """{"jsonrpc":"2.0","method":"calculator.addNumbers","params":[1],"id":4}"""
    )
    check invalidParams["error"]["code"].getInt() == RpcInvalidParams

    let parseFailure = adapter.response("{")
    check parseFailure["error"]["code"].getInt() == JsonRpcParseError
    check parseFailure["id"].kind == JNull

  test "batches omit notification responses":
    let
      sink = Counter()
      adapter = initAdapter(Counter(), sink)
      reply = adapter.response(
        """[
          {"jsonrpc":"2.0","method":"calculator.addNumbers","params":[2,3],"id":1},
          {"jsonrpc":"2.0","method":"events.valueChanged","params":[12]},
          {"jsonrpc":"2.0","method":"calculator.missing","id":2}
        ]"""
      )

    check reply.kind == JArray
    check reply.len == 2
    check reply[0]["result"].getInt() == 5
    check reply[1]["error"]["code"].getInt() == RpcMethodNotFound
    check sink.value == 12

  test "empty and notification-only batches follow JSON-RPC response rules":
    let adapter = initAdapter(Counter(), Counter())
    let empty = adapter.response("[]")
    check empty.kind == JObject
    check empty["error"]["code"].getInt() == RpcInvalidRequest

    let notifications = adapter.handleJsonRpc(
      """[
        {"jsonrpc":"2.0","method":"calculator.addNumbers","params":[1,2]},
        {"jsonrpc":"2.0","method":"calculator.currentAnswer"}
      ]"""
    )
    check notifications.isNone()

  test "selector transport runs locally on the application scheduler":
    let thread = newSigilSelectorThread()
    setLocalSigilThread(thread)
    let
      adapter = initAdapter(Counter(), Counter())
      dispatcher = newJsonRpcDispatcher(adapter)
      io = newJsonRpcSelectorIo()
    dispatcher.connectJsonRpc(io)
    emit dispatcher.jsonRpcStartRequested()
    check dispatcher.isListening

    let remote = splitAddress(dispatcher.boundAddress)
    let socket = newSocket(buffered = false)
    try:
      socket.connect(remote.host, remote.port)
      socket.send(
        """{"jsonrpc":"2.0","method":"calculator.addNumbers","params":[20,22],"id":1}
"""
      )
      var reply = ""
      for _ in 0..<20:
        discard thread.poll()
        if socket.hasDataBuffered():
          break
      reply = socket.recvLine(timeout = 2_000)
      check parseJson(reply)["result"].getInt() == 42
    finally:
      socket.close()
      emit dispatcher.jsonRpcStopRequested()
      thread.closeSelectorThread()
