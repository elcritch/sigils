import std/[isolation, monotimes, os, strutils, unittest]
import threading/atomics

import sigils
import sigils/threads

type
  CloneProbe = distinct int

  PayloadKind = enum
    TextPayload
    NumberPayload

  ManagedPayload = object
    id: int
    probe: CloneProbe
    case kind: PayloadKind
    of TextPayload:
      text: string
      tags: seq[string]
    of NumberPayload:
      numbers: seq[int]

  OwnershipProbe = object
    value: int
    state: int

  PayloadSource = ref object of AgentActor

  PayloadReceiver = ref object of AgentActor
    receiverId: int

  ProbeSource = ref object of AgentActor

  ProbeReceiver = ref object of AgentActor
    value: int

  DispatchProbeReceiver = ref object of ProbeReceiver
    methodCalls: int
    endpointCalls: int

const LiveOwnershipProbe = 1

var
  cloneCalls: Atomic[int]
  invalidPayloads: Atomic[int]
  receivedPayloads: array[2, Atomic[int]]
  ownershipProbeCopies: Atomic[int]
  ownershipProbeDestroys: Atomic[int]
  ownershipProbeReceived: Atomic[int]
  ownershipProbeValue: Atomic[int]

proc `=copy`(dest: var OwnershipProbe, src: OwnershipProbe) {.gcsafe.} =
  ownershipProbeCopies.atomicInc()
  dest.value = src.value
  dest.state = src.state

proc `=wasMoved`(probe: var OwnershipProbe) {.gcsafe.} =
  probe.value = 0
  probe.state = 0

proc `=destroy`(probe: var OwnershipProbe) {.gcsafe.} =
  if probe.state == LiveOwnershipProbe:
    ownershipProbeDestroys.atomicInc()
    probe.state = 0

proc clone(value: CloneProbe): CloneProbe {.gcsafe.} =
  cloneCalls.atomicInc()
  value

proc payloadChanged(source: PayloadSource,
    payload: sink ManagedPayload) {.signal.}

proc probeChanged(source: ProbeSource, payload: sink OwnershipProbe) {.signal.}

proc requestProbe(source: AgentProxy[ProbeSource], value: int) {.signal.}

proc requestProbe(source: ProbeSource, value: int) {.slot.} =
  emit source.probeChanged(OwnershipProbe(value: value,
      state: LiveOwnershipProbe))

proc valid(payload: ManagedPayload): bool =
  if int(payload.probe) != payload.id:
    return false

  case payload.kind
  of TextPayload:
    let letter = char(ord('a') + payload.id mod 26)
    payload.text == repeat(letter, 128) and
      payload.tags == @["item-" & $payload.id, "next-" & $(payload.id + 1)]
  of NumberPayload:
    payload.numbers == @[payload.id, payload.id + 1, payload.id + 2]

proc receivePayload(receiver: PayloadReceiver,
    payload: sink ManagedPayload) {.slot.} =
  if not payload.valid():
    invalidPayloads.atomicInc()
  receivedPayloads[receiver.receiverId].atomicInc()

proc receiveProbe(receiver: ProbeReceiver,
    payload: sink OwnershipProbe) {.slot.} =
  receiver.value = payload.value
  ownershipProbeValue.store(payload.value)
  ownershipProbeReceived.atomicInc()

method callMethod(
    receiver: DispatchProbeReceiver, req: sink SigilRequest, slot: AgentProc
): SigilResponse {.gcsafe, effectsOf: slot.} =
  inc receiver.methodCalls
  procCall callMethod(Agent(receiver), ensureMove(req), slot)

proc dispatchProbe(
    endpoint: AgentEndpoint,
    req: sink SigilRequest,
    slot: AgentProc,
    envSlot: EnvAgentProc,
    env: SlotEnv,
): SigilResponse {.gcsafe.} =
  let receiver = DispatchProbeReceiver(endpoint[].target[])
  inc receiver.endpointCalls
  {.cast(gcsafe).}:
    result = receiver.callMethod(ensureMove(req), slot)

proc payload(id: int): ManagedPayload =
  if id mod 2 == 0:
    ManagedPayload(
      id: id,
      probe: CloneProbe(id),
      kind: TextPayload,
      text: repeat(char(ord('a') + id mod 26), 128),
      tags: @["item-" & $id, "next-" & $(id + 1)],
    )
  else:
    ManagedPayload(
      id: id, probe: CloneProbe(id), kind: NumberPayload, numbers: @[id, id + 1,
          id + 2]
    )

proc waitForReceived(receiverId, expected: int) =
  for _ in 1 .. 5_000:
    if receivedPayloads[receiverId].load() == expected:
      return
    os.sleep(1)

proc resetCounters() =
  cloneCalls.store(0)
  invalidPayloads.store(0)
  ownershipProbeCopies.store(0)
  ownershipProbeDestroys.store(0)
  ownershipProbeReceived.store(0)
  ownershipProbeValue.store(0)
  for received in receivedPayloads.mitems:
    received.store(0)

suite "typed variant thread ownership":
  test "worker results move through the home proxy without copying":
    resetCounters()
    let thread = newSigilThread()
    thread.start()
    defer:
      thread.setRunning(false)
      thread.join()
    var source = ProbeSource()
    let receiver = ProbeReceiver()
    let proxy = source.moveToThread(thread)
    connectThreaded(proxy, requestProbe, proxy, requestProbe)
    connectThreaded(proxy, probeChanged, receiver, receiveProbe(ProbeReceiver))
    resetCounters()
    emit proxy.requestProbe(29)
    let deadline = getMonoTime() + initDuration(seconds = 5)
    while ownershipProbeReceived.load() != 1 and getMonoTime() < deadline:
      discard getCurrentSigilThread().pollAll()
      sleep(1)
    check receiver.value == 29
    check ownershipProbeReceived.load() == 1
    check ownershipProbeCopies.load() == 0
    check ownershipProbeDestroys.load() == 1

  test "isolated values pack and extract without copies and reject cloning":
    resetCounters()
    block:
      var isolated = isolate(OwnershipProbe(value: 31,
          state: LiveOwnershipProbe))
      var packed = rpcPack(move isolated)
      check packed.cloner.isNil
      expect ValueError:
        discard packed.clone()
      var unpacked: Isolated[OwnershipProbe]
      rpcUnpackMove(unpacked, move packed)
      let extracted = unpacked.extract()
      check extracted.value == 31
      check ownershipProbeCopies.load() == 0
    check ownershipProbeDestroys.load() == 1

  test "consumed packed delivery preserves dynamic callMethod overrides":
    resetCounters()
    let source = ProbeSource()
    let receiver = DispatchProbeReceiver()
    source.addSubscription(
      signalName(probeChanged), receiver, receiveProbe(ProbeReceiver)
    )
    emit source.probeChanged(OwnershipProbe(value: 37,
        state: LiveOwnershipProbe))
    check receiver.methodCalls == 1
    check receiver.value == 37
    check ownershipProbeCopies.load() == 0
    check ownershipProbeDestroys.load() == 1

  test "subscription-only endpoints route single and fanout deliveries":
    let source = ProbeSource()
    let first = DispatchProbeReceiver()
    let second = DispatchProbeReceiver()
    first.endpoint()[].dispatchSubscription = dispatchProbe
    second.endpoint()[].dispatchSubscription = dispatchProbe
    connect(source, probeChanged, first, receiveProbe)
    emit source.probeChanged(OwnershipProbe(value: 41,
        state: LiveOwnershipProbe))
    check first.endpointCalls == 1
    check first.methodCalls == 1
    connect(source, probeChanged, second, receiveProbe)
    emit source.probeChanged(OwnershipProbe(value: 43,
        state: LiveOwnershipProbe))
    check first.endpointCalls == 2
    check second.endpointCalls == 1
    check first.value == 43
    check second.value == 43

  test "consuming variant extraction rejects reuse":
    resetCounters()
    var source = OwnershipProbe(value: 11, state: LiveOwnershipProbe)
    let packed = newOwnedVariant(move source)
    let extracted = packed.takeVariant(OwnershipProbe)

    check extracted.value == 11
    expect Exception:
      discard packed.takeVariant(OwnershipProbe)

  test "public packed slots retain copy-preserving reuse":
    resetCounters()
    let receiver = ProbeReceiver()
    let slot = receiveProbe(ProbeReceiver)
    let packed = rpcPack((OwnershipProbe(value: 19, state: LiveOwnershipProbe), ))

    slot(receiver, packed)
    slot(receiver, packed)

    check ownershipProbeReceived.load() == 2
    check ownershipProbeValue.load() == 19

  test "reusable packed requests stay copy-preserving":
    resetCounters()
    let receiver = ProbeReceiver()
    receiver.addSubscription(
      signalName(probeChanged), receiver, ProbeReceiver.receiveProbe()
    )
    let request = initSigilRequest[ProbeSource, (OwnershipProbe, )](
      procName = signalName(probeChanged),
      args = (OwnershipProbe(value: 23, state: LiveOwnershipProbe), ),
    )

    emit((Agent(receiver), request))
    emit((Agent(receiver), request))

    check ownershipProbeReceived.load() == 2
    check ownershipProbeValue.load() == 23

  test "threaded sink payload honors custom move hooks throughout delivery":
    resetCounters()
    let
      thread = newSigilThread()
      source = ProbeSource()
    var receiver = ProbeReceiver()
    let proxy = receiver.moveToThread(thread)

    thread.start()
    connectThreaded(source, probeChanged, proxy, receiveProbe)
    ownershipProbeCopies.store(0)
    ownershipProbeDestroys.store(0)
    emit source.probeChanged(OwnershipProbe(value: 73,
        state: LiveOwnershipProbe))

    let deadline = getMonoTime() + initDuration(seconds = 5)
    for _ in 1 .. 5_000:
      if ownershipProbeReceived.load() == 1:
        break
      if getMonoTime() >= deadline:
        break
      os.sleep(1)
    check ownershipProbeReceived.load() == 1
    thread.setRunning(false)
    thread.join()

    check ownershipProbeValue.load() == 73
    check ownershipProbeCopies.load() == 0
    check ownershipProbeDestroys.load() == 1

  test "single recipient moves managed case payloads without cloning":
    const MessageCount = 100
    resetCounters()
    let
      thread = newSigilThread()
      source = PayloadSource()
    var receiver = PayloadReceiver(receiverId: 0)
    let proxy = receiver.moveToThread(thread)

    thread.start()
    connectThreaded(source, payloadChanged, proxy, receivePayload)
    for id in 0 ..< MessageCount:
      emit source.payloadChanged(payload(id))

    check cloneCalls.load() == 0
    waitForReceived(0, MessageCount)
    check receivedPayloads[0].load() == MessageCount
    check invalidPayloads.load() == 0

    thread.setRunning(false)
    thread.join()

  test "fanout applies the memory manager clone policy":
    const MessageCount = 100
    resetCounters()
    let
      thread = newSigilThread()
      source = PayloadSource()
    var
      first = PayloadReceiver(receiverId: 0)
      second = PayloadReceiver(receiverId: 1)
    let
      firstProxy = first.moveToThread(thread)
      secondProxy = second.moveToThread(thread)

    thread.start()
    connectThreaded(source, payloadChanged, firstProxy, receivePayload)
    connectThreaded(source, payloadChanged, secondProxy, receivePayload)
    for id in 0 ..< MessageCount:
      emit source.payloadChanged(payload(id))

    when defined(gcAtomicArc):
      check cloneCalls.load() == 0
    else:
      check cloneCalls.load() == MessageCount
    waitForReceived(0, MessageCount)
    waitForReceived(1, MessageCount)
    check receivedPayloads[0].load() == MessageCount
    check receivedPayloads[1].load() == MessageCount
    check invalidPayloads.load() == 0

    thread.setRunning(false)
    thread.join()
