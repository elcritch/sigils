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

proc changed(source: MutationSource) {.signal.}

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

  test "local fanout owns the next subscription across mutation":
    let
      source = MutationSource()
      mutator = MutationReceiver(source: source)
      observer = Observer()
    connectReceivers(source, mutator, observer, packed = false)

    emit source.changed()

    check mutator.calls == 1
    check mutator.replacementCalls == 0
    check observer.calls == 1

  test "packed fanout owns the next subscription across mutation":
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
