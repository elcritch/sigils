import std/unittest
import sigils/selectors

type
  TrackedPayload = object
    values: seq[int]
  PayloadReceiver = ref object of DynamicAgent
    retained: seq[int]

var payloadCopies: int

proc `=copy`(dest: var TrackedPayload, source: TrackedPayload) =
  inc payloadCopies
  dest.values = source.values

proc `=dup`(source: TrackedPayload): TrackedPayload =
  inc payloadCopies
  result.values = source.values

method inspectPayload(payload: TrackedPayload): int {.selector.}
method inspectPair(payload: TrackedPayload, offset: int): int {.selector.}

method inspectPayloadImpl(self: PayloadReceiver,
    payload: TrackedPayload): int {.selector.} =
  self.retained = payload.values
  result = payload.values[0]

method inspectPairImpl(self: PayloadReceiver, payload: TrackedPayload,
    offset: int): int {.selector.} =
  result = payload.values[0] + offset

proc inspectCallback(self: PayloadReceiver, payload: TrackedPayload): int =
  self.retained = payload.values
  result = payload.values[0]

protocol PayloadProtocol:
  method protocolValue(payload: TrackedPayload): int

protocol PayloadImplementation of PayloadProtocol:
  method protocolValue(self: PayloadReceiver, payload: TrackedPayload): int =
    self.retained = payload.values
    result = payload.values[0]

proc invokeTwice(self: DynamicAgent, invocation: var Invocation,
    next: DynamicMethod) =
  next(self, invocation)
  let first = invocation.resultAs(int)
  next(self, invocation)
  invocation.setResult(first + invocation.resultAs(int))

suite "selector payload ownership":
  test "local generated adapters borrow single arguments":
    let receiver = PayloadReceiver()
    doAssert receiver.addMethod(inspectPayload, inspectPayloadImpl)
    var payload = TrackedPayload(values: @[41])
    payloadCopies = 0
    let value = receiver.send(inspectPayload, move(payload))
    check value == 41
    check payloadCopies == 0
    check receiver.retained == @[41]

  test "local generated adapters borrow tuple arguments":
    let receiver = PayloadReceiver()
    doAssert receiver.addMethod(inspectPair, inspectPairImpl)
    var args = (payload: TrackedPayload(values: @[41]), offset: 1)
    payloadCopies = 0
    let value = receiver.send(inspectPair, move(args))
    check value == 42
    check payloadCopies == 0

  test "typed callback adapters borrow arguments":
    let receiver = PayloadReceiver()
    doAssert receiver.addMethod(inspectPayload, toDynamicMethod(inspectCallback))
    var payload = TrackedPayload(values: @[41])
    payloadCopies = 0
    let value = receiver.send(inspectPayload, move(payload))
    check value == 41
    check payloadCopies == 0
    check receiver.retained == @[41]

  test "packed invocations remain reusable":
    let receiver = PayloadReceiver()
    doAssert receiver.addMethod(inspectPayload, inspectPayloadImpl)
    var invocation = initInvocation(inspectPayload.name, TrackedPayload(
        values: @[41]))
    check receiver.dispatch(invocation)
    check invocation.resultAs(int) == 41
    check receiver.dispatch(invocation)
    check invocation.resultAs(int) == 41
    check invocation.argsAs(TrackedPayload).values == @[41]

  test "protocol implementation adapters borrow arguments":
    let receiver = PayloadReceiver().withProtocol(PayloadImplementation)
    var payload = TrackedPayload(values: @[41])
    payloadCopies = 0
    let value = receiver.send(protocolValue, move(payload))
    check value == 41
    check payloadCopies == 0
    check receiver.retained == @[41]

  test "around methods can invoke the same borrowed payload twice":
    let receiver = PayloadReceiver()
    doAssert receiver.addMethod(inspectPayload, inspectPayloadImpl)
    let token = receiver.pushMethod(inspectPayload, invokeTwice)
    var payload = TrackedPayload(values: @[41])
    payloadCopies = 0
    let value = receiver.send(inspectPayload, move(payload))
    check value == 82
    check payloadCopies == 0
    check token.popMethod()

  test "public argsAs still returns an independent value":
    var invocation = initInvocation(inspectPayload.name, TrackedPayload(
        values: @[41]))
    var copy = invocation.argsAs(TrackedPayload)
    copy.values[0] = 99
    check invocation.argsAs(TrackedPayload).values == @[41]

  when sigilsClosuresEnabled:
    test "typed receiver closures can retain a borrowed argument":
      let receiver = PayloadReceiver()
      let increment = 1
      let binding = selectorMethod(inspectPayload) do(self: PayloadReceiver,
          payload: TrackedPayload) -> int:
        self.retained = payload.values
        payload.values[0] + increment
      discard receiver.replaceMethod(inspectPayload, binding.implementation)
      var payload = TrackedPayload(values: @[41])
      payloadCopies = 0
      let value = receiver.send(inspectPayload, move(payload))
      check value == 42
      check payloadCopies == 0
      check receiver.retained == @[41]
