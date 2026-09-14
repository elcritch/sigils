import std/[net, options, unittest]

import sigils
import sigils/threadSelectors
import sigils/rpcs/cborRpc
import sigils/rpcs/cbor/[crAgents, crFraming, crSelector]

import cborRpcTestUtils

type
  Counter = ref object of Agent
    value: int

  CounterSource = ref object of Agent

  AddArgs = tuple[left: int, right: int]

proc setValue(self: Counter, value: int) {.slot.} =
  self.value = value

proc valueChanged(self: CounterSource, value: int) {.signal.}

let addNumbers = selector[AddArgs, int]("addNumbers")

proc addImpl(self: DynamicAgent, args: AddArgs): int =
  args.left + args.right

proc initRouter(counter, sink: Counter): CborRpcRouter =
  let
    source = CounterSource()
    calculator = DynamicAgent()
  discard calculator.addMethod(addNumbers, toDynamicMethod(addImpl))
  result = newCborRpcRouter()
  result.registerSelector("calculator", calculator, addNumbers)
  result.registerSlot("counter", "setValue", counter, Counter.setValue())
  result.registerSignal("events", source, toSigilName("valueChanged"))
  connect(source, valueChanged, sink, setValue)

suite "CBOR-RPC protocol adapter":
  test "routes typed selectors, slots, and notifications":
    let
      counter = Counter()
      sink = Counter()
      router = initRouter(counter, sink)
      selectorRequest = cborRpcRequestEnvelope(
        1,
        "calculator",
        "addNumbers",
        packCborRpcPayload((left: 20, right: 22)),
      )
      selectorResponse = router.handleCborRpc(
        encodeCborRpcEnvelope(selectorRequest)
      )

    check selectorResponse.isSome()
    let decoded = decodeCborRpcEnvelope(selectorResponse.get())
    check decoded.kind == CborRpcResponse
    check decoded.id == 1
    check unpackCborRpcPayload(decoded.payload, int) == 42

    let slotResponse = router.handleCborRpc(encodeCborRpcEnvelope(
      cborRpcRequestEnvelope(
        2,
        "counter",
        "setValue",
        packCborRpcPayload((71, )),
      )
    ))
    check slotResponse.isSome()
    check unpackCborRpcPayload(
      decodeCborRpcEnvelope(slotResponse.get()).payload,
      bool,
    )
    check counter.value == 71

    let notification = router.handleCborRpc(encodeCborRpcEnvelope(
      cborRpcNotifyEnvelope(
        "events",
        "valueChanged",
        packCborRpcPayload((99, )),
      )
    ))
    check notification.isNone()
    check sink.value == 99

  test "returns structured route errors":
    let response = initRouter(Counter(), Counter()).handleCborRpc(
      encodeCborRpcEnvelope(cborRpcRequestEnvelope(
        3,
        "missing",
        "unknown",
        packCborRpcPayload(()),
      ))
    )
    check response.isSome()
    let decoded = decodeCborRpcEnvelope(response.get())
    check decoded.kind == CborRpcError
    check decoded.id == 3
    check decoded.errorCode == CborRpcMethodNotFound

  test "incremental framing accepts partial and consecutive frames":
    let
      first = frameCborRpcPayload("first")
      second = frameCborRpcPayload("second")
    var parser = initCborRpcFrameParser()
    parser.add(first[0..3])
    check parser.nextFrame().isNone()
    parser.add(first[4..^1] & second)
    check parser.nextFrame().get() == "first"
    check parser.nextFrame().get() == "second"
    check parser.nextFrame().isNone()

  test "selector transport runs on the application scheduler":
    let thread = newSigilSelectorThread()
    setLocalSigilThread(thread)
    let
      dispatcher = newCborRpcDispatcher(initRouter(Counter(), Counter()))
      io = newCborRpcSelectorIo()
    dispatcher.connectCborRpc(io)
    emit dispatcher.cborRpcStartRequested()
    check dispatcher.isListening

    let
      remote = splitTcpAddress(dispatcher.boundAddress)
      socket = newSocket(buffered = false)
      request = encodeCborRpcEnvelope(cborRpcRequestEnvelope(
        4,
        "calculator",
        "addNumbers",
        packCborRpcPayload((left: 8, right: 9)),
      ))
    try:
      socket.connect(remote.host, remote.port)
      socket.send(frameCborRpcPayload(request))
      for _ in 0..<20:
        discard thread.poll()
      let response = decodeCborRpcEnvelope(socket.recvCborRpcFrame())
      check response.kind == CborRpcResponse
      check unpackCborRpcPayload(response.payload, int) == 17
    finally:
      socket.close()
      emit dispatcher.cborRpcStopRequested()
      thread.closeSelectorThread()
