import std/[os, strutils, unittest]

import chronos

import sigils
import sigils/ipc

type
  Counter = ref object of Agent
    value: int

  CounterSource = ref object of Agent

  AddArgs = tuple[left: int, right: int]

  IpcFixture = object
    local: tuple[address: TransportAddress, path: string]
    counter: Counter
    sink: Counter
    server: IpcServer

proc setValue(self: Counter, value: int) {.slot.} =
  self.value = value

proc valueChanged(self: CounterSource, value: int) {.signal.}

let addNumbers = selector[AddArgs, int]("addNumbers")

proc addImpl(self: DynamicAgent, args: AddArgs): int =
  args.left + args.right

proc localIpcAddress(): tuple[address: TransportAddress, path: string] =
  when defined(windows):
    let path = "/sigils-ipc-" & $getCurrentProcessId()
  else:
    let path = getTempDir() / ("sigils-ipc-" & $getCurrentProcessId() & ".sock")
  (initTAddress(path), path)

proc initIpcFixture(): IpcFixture =
  let
    router = newIpcRouter()
    source = CounterSource()
    calculator = DynamicAgent()

  result.local = localIpcAddress()
  when not defined(windows):
    discard tryRemoveFile(result.local.path)
  result.counter = Counter()
  result.sink = Counter()
  discard calculator.addMethod(addNumbers, toDynamicMethod(addImpl))
  let calculatorProtocol = initProtocol(
    "Calculator",
    [requirement(addNumbers)],
  )
  router.registerProtocol("calculator", calculator, calculatorProtocol)
  router.registerSlot(
    "counter",
    "setValue",
    result.counter,
    Counter.setValue(),
  )
  router.registerSignal("events", source, toSigilName("valueChanged"))
  connect(source, valueChanged, result.sink, setValue)
  result.server = createIpcServer(result.local.address, router)
  result.server.start()

proc runIpcRoundTrip(fixture: ptr IpcFixture): Future[tuple[
    sum: int,
    slotResult: bool,
    counterValue: int,
    sinkValue: int,
    concurrentTotal: int,
    missingCode: int32,
    invalidParamsCode: int32,
    oversizedNameCode: int32,
]] {.async.} =
  let peer = await connectIpc(fixture[].server.localAddress())
  try:
    result.sum = await peer.callSelector(
      "calculator",
      addNumbers,
      (left: 20, right: 22),
    )
    result.slotResult = await peer.callSlot("counter", "setValue", (71, ))
    result.counterValue = fixture[].counter.value

    await peer.notifySignal("events", "valueChanged", (99, ))
    await sleepAsync(chronos.milliseconds(10))
    result.sinkValue = fixture[].sink.value

    let
      first = peer.callSelector(
        "calculator",
        addNumbers,
        (left: 1, right: 2),
      )
      second = peer.callSelector(
        "calculator",
        addNumbers,
        (left: 3, right: 4),
      )
    let
      firstValue = await first
      secondValue = await second
    result.concurrentTotal = firstValue + secondValue

    try:
      discard await peer.callRaw("missing", "unknown", packIpcPayload(()))
    except IpcRemoteError as error:
      result.missingCode = error.code

    try:
      discard await peer.callRaw(
        "calculator",
        "addNumbers",
        packIpcPayload("not AddArgs"),
      )
    except IpcRemoteError as error:
      result.invalidParamsCode = error.code

    try:
      discard await peer.callRaw(
        "calculator",
        repeat("x", sigilsMaxSignalLength + 1),
        packIpcPayload(()),
      )
    except IpcRemoteError as error:
      result.oversizedNameCode = error.code
  finally:
    await peer.closeWait()
    await fixture[].server.closeWait()
    when not defined(windows):
      discard tryRemoveFile(fixture[].local.path)

suite "Chronos IPC":
  test "CBOR envelope round trip":
    let original = requestEnvelope(
      41,
      "calculator",
      "addNumbers",
      packIpcPayload((left: 1, right: 2)),
    )
    let decoded = decodeEnvelope(encodeEnvelope(original))

    check decoded.version == IpcProtocolVersion
    check decoded.kind == IpcRequest
    check decoded.id == 41
    check decoded.target == "calculator"
    check decoded.name == "addNumbers"
    check unpackIpcPayload(decoded.payload, AddArgs) == (left: 1, right: 2)

  test "frames reject empty and oversized messages":
    expect IpcFrameError:
      discard framePayload("")
    expect IpcFrameError:
      discard framePayload("12345", 4)
    expect IpcFrameError:
      discard framePayload("1", 0)

  test "outgoing routes require a target and name":
    var fixture = initIpcFixture()
    proc runInvalidRoute(fixture: ptr IpcFixture): Future[tuple[
        callRejected: bool,
        notifyRejected: bool,
    ]] {.async.} =
      let peer = await connectIpc(fixture[].server.localAddress())
      try:
        try:
          discard await peer.callRaw("", "addNumbers", packIpcPayload(()))
        except ValueError:
          result.callRejected = true
        try:
          await peer.notifySignal("events", "", ())
        except ValueError:
          result.notifyRejected = true
      finally:
        await peer.closeWait()
        await fixture[].server.closeWait()
        when not defined(windows):
          discard tryRemoveFile(fixture[].local.path)

    let rejected = waitFor runInvalidRoute(addr fixture)
    check rejected.callRejected
    check rejected.notifyRejected

  test "slots, signals, and protocol selectors cross a local stream":
    var fixture = initIpcFixture()
    let values = waitFor runIpcRoundTrip(addr fixture)
    check values.sum == 42
    check values.slotResult
    check values.counterValue == 71
    check values.sinkValue == 99
    check values.concurrentTotal == 10
    check values.missingCode == IpcMethodNotFound
    check values.invalidParamsCode == IpcInvalidParams
    check values.oversizedNameCode == IpcInvalidRequest
