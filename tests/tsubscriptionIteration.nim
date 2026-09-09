import std/unittest

import sigils

type
  MutationSource = ref object of Agent

  MutationReceiver = ref object of Agent
    source: MutationSource
    calls: int
    replacementCalls: int
    packed: bool

  Observer = ref object of Agent
    calls: int

  DisposableReceiver = ref object of Agent
    owner: ptr DisposableReceiver

proc changed(source: MutationSource) {.signal.}
proc unrelated(source: MutationSource) {.signal.}

proc replacement(receiver: MutationReceiver) {.slot.} =
  receiver.replacementCalls.inc()

proc mutate(receiver: MutationReceiver) {.slot.} =
  receiver.calls.inc()
  disconnect(receiver.source, changed, receiver)
  if receiver.packed:
    let packedSlot: AgentProc = MutationReceiver.replacement()
    receiver.source.addSubscription(
      signalName(changed), receiver, packedSlot
    )
  else:
    connect(receiver.source, changed, receiver, replacement)

proc observe(observer: Observer) {.slot.} =
  observer.calls.inc()

proc disconnectAndRaise(receiver: MutationReceiver) {.slot.} =
  disconnect(receiver.source, changed, receiver)
  raise newException(ValueError, "slot disconnected before raising")

proc dispose(receiver: DisposableReceiver) {.slot.} =
  receiver.owner[] = nil

proc connectReceivers(
    source: MutationSource,
    mutator: MutationReceiver,
    observer: Observer,
    packed: bool,
) =
  if packed:
    let
      mutatingSlot: AgentProc = MutationReceiver.mutate()
      observingSlot: AgentProc = Observer.observe()
    source.addSubscription(signalName(changed), mutator, mutatingSlot)
    source.addSubscription(signalName(changed), observer, observingSlot)
  else:
    connect(source, changed, mutator, mutate)
    connect(source, changed, observer, observe)

suite "subscription iteration":
  test "sole local slot can destroy its receiver during delivery":
    let source = MutationSource()
    var receiver = DisposableReceiver()
    receiver.owner = addr receiver
    connect(source, changed, receiver, dispose)

    emit source.changed()
    check receiver.isNil
    check source.subcriptions.len == 0

  test "sole local slot can replace its subscription during delivery":
    let source = MutationSource()
    let receiver = MutationReceiver(source: source)
    connect(source, changed, receiver, mutate)

    emit source.changed()
    check receiver.calls == 1
    check receiver.replacementCalls == 0
    emit source.changed()
    check receiver.replacementCalls == 1

  test "sole local slot can disconnect and raise":
    let source = MutationSource()
    let receiver = MutationReceiver(source: source)
    connect(source, changed, receiver, disconnectAndRaise)

    expect ValueError:
      emit source.changed()
    check source.subcriptions.len == 0
    emit source.changed()

  test "sole local slot respects exact and wildcard signal names":
    let source = MutationSource()
    let observer = Observer()
    connect(source, changed, observer, observe)

    emit source.unrelated()
    check observer.calls == 0
    emit source.changed()
    check observer.calls == 1
    source.subcriptions[0].signal = AnySigilName
    emit source.unrelated()
    check observer.calls == 2

  test "sole local slot skips a closed delivery endpoint":
    let source = MutationSource()
    let observer = Observer()
    connect(source, changed, observer, observe)
    observer.closeEndpoint()

    emit source.changed()
    check observer.calls == 0

  test "large fanout visits every subscription":
    let source = MutationSource()
    var observers: seq[Observer]
    for _ in 0 ..< 32:
      let observer = Observer()
      observers.add(observer)
      connect(source, changed, observer, observe)

    emit source.changed()

    for observer in observers:
      check observer.calls == 1

  test "local fanout preserves the next subscription across mutation":
    let
      source = MutationSource()
      mutator = MutationReceiver(source: source)
      observer = Observer()
    connectReceivers(source, mutator, observer, packed = false)

    emit source.changed()

    check mutator.calls == 1
    check mutator.replacementCalls == 0
    check observer.calls == 1

  test "packed fanout preserves the next subscription across mutation":
    let
      source = MutationSource()
      mutator = MutationReceiver(source: source, packed: true)
      observer = Observer()
    connectReceivers(source, mutator, observer, packed = true)
    source.callSlots(
      initSigilRequest[MutationSource, tuple[]](
        procName = signalName(changed),
        args = default(tuple[]),
      )
    )

    check mutator.calls == 1
    check mutator.replacementCalls == 0
    check observer.calls == 1
