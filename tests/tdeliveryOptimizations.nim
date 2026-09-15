import std/[sequtils, unittest]

import sigils
import sigils/selectors

type
  HookSource = ref object of Agent
    connections: int
    deliveryUpdates: int

  DupPayload = object
    value: int
    live: bool

  MoveOnly = object
    value: int

  Receiver = ref object of Agent
    calls: int
    value: int

  TextReceiver = ref object of DynamicAgent

  GenericReceiver[T] = ref object of Agent
    value: T

var copies, duplicates, destroys: int
var rejectDuplicate: bool

proc `=copy`(dest: var MoveOnly, source: MoveOnly) {.error.}
proc `=dup`(source: MoveOnly): MoveOnly {.error.}

proc `=destroy`(payload: var DupPayload) =
  if payload.live:
    inc destroys
    payload.live = false

proc `=copy`(dest: var DupPayload, source: DupPayload) =
  inc copies
  `=destroy`(dest)
  dest.value = source.value
  dest.live = source.live

proc `=wasMoved`(payload: var DupPayload) =
  payload.live = false

proc `=dup`(source: DupPayload): DupPayload =
  inc duplicates
  if rejectDuplicate:
    raise newException(ValueError, "duplicate rejected")
  result = DupPayload(value: source.value, live: source.live)

proc changed(source: Agent, value: int) {.signal.}
proc payloadChanged(source: Agent, payload: sink DupPayload) {.signal.}
proc borrowedPayloadChanged(source: Agent, payload: DupPayload) {.signal.}
proc groupedChanged(source: Agent, first, second: sink DupPayload) {.signal.}
proc sequenceChanged(source: Agent, values: sink seq[int]) {.signal.}

proc receive(receiver: Receiver, value: int) {.slot.} =
  inc receiver.calls
  receiver.value = value

proc receivePayload(receiver: Receiver, payload: sink DupPayload) {.slot.} =
  inc receiver.calls
  receiver.value = payload.value

proc receiveMoveOnly(receiver: Receiver, payload: sink MoveOnly) {.slot.} =
  inc receiver.calls
  receiver.value = payload.value

proc receiveGrouped(receiver: Receiver, first,
    second: sink DupPayload) {.slot.} =
  inc receiver.calls
  receiver.value = first.value + second.value

proc receiveGeneric[T](receiver: GenericReceiver[T], value: sink T) {.slot.} =
  receiver.value = ensureMove(value)

method addSubscription(source: HookSource, signal: SigilName,
    target: WeakRef[Agent], slot: AgentProc, directSlot: LocalAgentProc
) {.gcsafe, raises: [].} =
  inc source.connections
  procCall addSubscription(Agent(source), signal, target, slot, directSlot)

method updateSubscriptionDelivery(source: HookSource, signal: SigilName,
    subscription: Subscription
) {.gcsafe, raises: [].} =
  inc source.deliveryUpdates
  procCall updateSubscriptionDelivery(Agent(source), signal, subscription)

method textResult(text: string): string {.selector.}

method makeText(receiver: TextReceiver, text: string): string {.selector.} =
  if text == "raise":
    raise newException(ValueError, "selector rejected argument")
  "result:" & text

proc resetHooks() =
  copies = 0
  duplicates = 0
  destroys = 0
  rejectDuplicate = false

suite "delivery optimizations":
  test "ordinary reconnect uses the legacy hook without a metadata update":
    let source = HookSource()
    let receiver = Receiver()
    connect(source, changed, receiver, receive(Receiver))
    for _ in 0..<100:
      connect(source, changed, receiver, receive)
    check source.connections == 100
    check source.deliveryUpdates == 0
    check source.subcriptions.len == 1
    check receiver.listening.len == 1
    check not source.subcriptions[0].subscription.directSlot.isNil
    emit source.changed(42)
    check receiver.calls == 1
    check receiver.value == 42

  test "sink reconnect upgrades a packed handler without changing its identity":
    let source = HookSource()
    let first = Receiver()
    let second = Receiver()
    connect(source, payloadChanged, first, receivePayload(Receiver))
    for _ in 0..<10:
      connect(source, payloadChanged, first, receivePayload)
    connect(source, payloadChanged, second, receivePayload)
    check source.connections == 11
    check source.deliveryUpdates == 11
    check source.subcriptions.len == 2
    check first.listening.len == 1
    for subscription in source.getSubscriptions(signalName(payloadChanged)):
      check not subscription.directSlot.isNil
      check not subscription.directSlotClone.isNil
    resetHooks()
    emit source.payloadChanged(DupPayload(value: 37, live: true))
    check first.value == 37
    check second.value == 37
    check first.calls == 1
    check second.calls == 1
    check copies == 0
    check duplicates == 1
    check destroys == 2

  test "actor reconnect retains delivery metadata under its registration hooks":
    let source = AgentActor()
    let first = Receiver()
    let second = Receiver()
    connect(source, payloadChanged, first, receivePayload(Receiver))
    for _ in 0..<10:
      connect(source, payloadChanged, first, receivePayload)
    connect(source, payloadChanged, second, receivePayload)
    check source.getSubscriptions(signalName(payloadChanged)).toSeq.len == 2
    resetHooks()
    emit source.payloadChanged(DupPayload(value: 39, live: true))
    check first.value == 39
    check second.value == 39
    check duplicates == 1
    check copies == 0
    check destroys == 2

  test "a non-sink signal still duplicates for consuming receivers":
    let source = Agent()
    let first = Receiver()
    let second = Receiver()
    connect(source, borrowedPayloadChanged, first, receivePayload)
    connect(source, borrowedPayloadChanged, second, receivePayload)
    resetHooks()
    let payload = DupPayload(value: 41, live: true)
    emit source.borrowedPayloadChanged(payload)
    check first.value == 41
    check second.value == 41
    check payload.value == 41
    check payload.live

  test "grouped sink fanout duplicates each field and moves the final delivery":
    let source = Agent()
    let first = Receiver()
    let second = Receiver()
    connect(source, groupedChanged, first, receiveGrouped)
    connect(source, groupedChanged, second, receiveGrouped)
    resetHooks()
    emit source.groupedChanged(DupPayload(value: 17, live: true),
        DupPayload(value: 25, live: true))
    check first.value == 42
    check second.value == 42
    check copies == 0
    check duplicates == 2
    check destroys == 4

  test "a failed sink duplicate releases the original and preserves connections":
    let source = Agent()
    let first = Receiver()
    let second = Receiver()
    connect(source, payloadChanged, first, receivePayload)
    connect(source, payloadChanged, second, receivePayload)
    resetHooks()
    rejectDuplicate = true
    expect ValueError:
      emit source.payloadChanged(DupPayload(value: 43, live: true))
    check first.calls == 0
    check second.calls == 0
    check destroys == 1
    rejectDuplicate = false
    emit source.payloadChanged(DupPayload(value: 47, live: true))
    check first.value == 47
    check second.value == 47
    check destroys == 3

  test "direct sink callback rejects a forbidden duplicate before consuming":
    # This exercises the generated direct callbacks, not general move-only
    # signal packing (which still requires a tuple cloner).
    let receiver = Receiver()
    var args = (MoveOnly(value: 53), )
    let cloneSlot = receiveMoveOnly(LocalSignalTypes, Receiver, LocalSlotCloneInfo)
    expect ValueError:
      cloneSlot(receiver, addr args, CloneMode.Rc)
    check args[0].value == 53
    check receiver.calls == 0
    let directSlot = receiveMoveOnly(LocalSignalTypes, Receiver)
    directSlot(receiver, addr args)
    check receiver.value == 53
    check receiver.calls == 1

  test "generic sink slots receive independently owned sequence values":
    let source = Agent()
    let first = GenericReceiver[seq[int]]()
    let second = GenericReceiver[seq[int]]()
    connect(source, sequenceChanged, first, receiveGeneric)
    connect(source, sequenceChanged, second, receiveGeneric)
    emit source.sequenceChanged(@[17, 25])
    check first.value == @[17, 25]
    check second.value == @[17, 25]
    first.value[0] = 99
    check second.value == @[17, 25]

  test "local invocation initializes unused fields on success and exceptions":
    let receiver = TextReceiver()
    var value = "unchanged"
    check not receiver.perform(textResult, "unhandled", value)
    check not receiver.performLocal(textResult, "unhandled", value)
    check not receiver.performNext(textResult, "unhandled", value)
    check value == "unchanged"
    check receiver.addMethod(textResult, makeText)
    let token = receiver.pushMethod(textResult, makeText)
    for _ in 0..<10:
      expect ValueError:
        discard receiver.perform(textResult, "raise", value)
      expect ValueError:
        discard receiver.performLocal(textResult, "raise", value)
      expect ValueError:
        discard receiver.performNext(textResult, "raise", value)
      check receiver.perform(textResult, "normal", value)
      check value == "result:normal"
      check receiver.performLocal(textResult, "local", value)
      check value == "result:local"
      check receiver.performNext(textResult, "next", value)
      check value == "result:next"
    check token.popMethod()
