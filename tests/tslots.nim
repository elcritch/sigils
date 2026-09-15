import sigils/signals
import sigils/slots
import sigils/core

import std/monotimes

type
  Counter* = ref object of Agent
    value: int
    avg: int64
    identity: IdentityPayload

  Originator* = ref object of Agent

  GenericOriginator*[T] = ref object of Agent

  IdentityPayload = ref object of Agent
    value: int

  OwnedPayload = object
    value: int

  MoveTrackedPayload = object
    value: int
    state: int

  CounterWithDestroy* = ref object of Agent
    value: int
    avg: int64

const LiveMoveTrackedPayload = 1

var
  moveTrackedCopies: int
  moveTrackedDestroys: int

proc `=copy`(dest: var MoveTrackedPayload, src: MoveTrackedPayload) =
  inc moveTrackedCopies
  dest.value = src.value
  dest.state = src.state

proc `=wasMoved`(payload: var MoveTrackedPayload) =
  payload.value = 0
  payload.state = 0

proc `=destroy`(payload: var MoveTrackedPayload) =
  if payload.state == LiveMoveTrackedPayload:
    inc moveTrackedDestroys
    payload.state = 0

proc `=destroy`*(x: var typeof(CounterWithDestroy()[])) =
  when defined(sigilsDebug):
    echo "CounterWithDestroy:destroy: ", x.debugName
  destroyAgent(x)

proc change*(tp: Originator, val: int) {.signal.}
proc payloadChanged*(tp: Originator, payload: sink OwnedPayload) {.signal.}
proc trackedPayloadChanged*(tp: Originator,
    payload: sink MoveTrackedPayload) {.signal.}
proc groupedTrackedPayloadChanged*(
  tp: Originator, first, second: sink MoveTrackedPayload
) {.signal.}

proc identityChanged*(tp: Originator, payload: IdentityPayload) {.signal.}
proc sinkIdentityChanged*(tp: Originator,
    payload: sink IdentityPayload) {.signal.}
proc mixedChanged*(
  tp: Originator, identity: IdentityPayload, payload: sink MoveTrackedPayload
) {.signal.}

proc genericSinkChanged*[T](tp: GenericOriginator[T],
    payload: sink T) {.signal.}

proc valueChanged*(tp: Counter, val: int) {.signal.}
proc valueChanged*(tp: CounterWithDestroy, val: int) {.signal.}

proc someChange*(tp: Counter) {.signal.}

proc avgChanged*(tp: Counter, val: float) {.signal.}

proc setValue*(self: Counter, value: int) {.slot.} =
  echo "setValue! ", value
  if self.value != value:
    self.value = value
    emit self.valueChanged(value)

proc setPayload*(self: Counter, payload: sink OwnedPayload) {.slot.} =
  self.value = payload.value

proc setTrackedPayload*(self: Counter, payload: sink MoveTrackedPayload) {.slot.} =
  self.value = payload.value

proc setGroupedTrackedPayload*(
    self: Counter, first, second: sink MoveTrackedPayload
) {.slot.} =
  self.value = first.value + second.value

proc setIdentity*(self: Counter, payload: IdentityPayload) {.slot.} =
  self.value = payload.value

proc setSinkIdentity*(self: Counter, payload: sink IdentityPayload) {.slot.} =
  self.identity = payload
  self.value = payload.value

proc setMixed*(
    self: Counter, identity: IdentityPayload, payload: sink MoveTrackedPayload
) {.slot.} =
  self.identity = identity
  self.value = payload.value

proc setGenericInt*(self: Counter, payload: sink int) {.slot.} =
  self.value = payload

proc setValue*(self: CounterWithDestroy, value: int) {.slot.} =
  echo "setValue! ", value
  if self.value != value:
    self.value = value
    emit self.valueChanged(value)

proc setSomeValue*(self: Counter, value: int) =
  echo "setValue! ", value
  if self.value != value:
    self.value = value
    emit self.valueChanged(value)

proc someAction*(self: Counter) {.slot.} =
  echo "action"
  self.avg = -1

proc someOtherAction*(self: Counter) {.slot.} =
  echo "action"
  self.avg = -1

proc value*(self: Counter): int =
  self.value

proc doTick*(fig: Counter, tickCount: int, now: MonoTime) {.signal.}

proc someTick*(self: Counter, tick: int, now: MonoTime) {.slot.} =
  echo "tick: ", tick, " now: ", now
  self.avg = now.ticks

proc someTickOther*(self: Counter, tick: int, now: MonoTime) {.slot.} =
  echo "tick: ", tick, " now: ", now

when isMainModule:
  import unittest
  import std/sequtils

  suite "agent slots":
    setup:
      var
        a {.used.} = Counter()
        b {.used.} = Counter()
        c {.used.} = Counter()
        d {.used.} = Counter()
        o {.used.} = Originator()

      when defined(sigilsDebug):
        a.debugName = "A"
        b.debugName = "B"
        c.debugName = "C"
        d.debugName = "D"
        o.debugName = "O"

    teardown:
      GC_fullCollect()

    test "signal / slot types":
      check SignalTypes.avgChanged(Counter) is (float, )
      check SignalTypes.valueChanged(Counter) is (int, )
      echo "someChange: ", SignalTypes.someChange(Counter).typeof.repr
      check SignalTypes.someChange(Counter) is tuple[]
      check SignalTypes.setValue(Counter) is (int, )
      check SignalTypes.payloadChanged(Originator) is (OwnedPayload, )
      check SignalTypes.setPayload(Counter) is (OwnedPayload, )
      check SignalTypes.trackedPayloadChanged(Originator) is (
          MoveTrackedPayload, )
      check SignalTypes.setTrackedPayload(Counter) is (MoveTrackedPayload, )
      check SignalTypes.groupedTrackedPayloadChanged(Originator) is
        (MoveTrackedPayload, MoveTrackedPayload)
      check SignalTypes.setGroupedTrackedPayload(Counter) is
        (MoveTrackedPayload, MoveTrackedPayload)
      check SignalTypes.identityChanged(Originator) is (IdentityPayload, )
      check SignalTypes.setIdentity(Counter) is (IdentityPayload, )
      check SignalTypes.mixedChanged(Originator) is (
        IdentityPayload, MoveTrackedPayload
      )
      check SignalTypes.setMixed(Counter) is (IdentityPayload, MoveTrackedPayload)

    test "sink signal and slot payloads expose their value type":
      connect(o, payloadChanged, b, setPayload)
      var payload = OwnedPayload(value: 42)

      emit o.payloadChanged(move payload)

      check b.value == 42

    test "sink payload moves through local tuple packing and delivery":
      moveTrackedCopies = 0
      moveTrackedDestroys = 0
      connect(o, trackedPayloadChanged, b, setTrackedPayload)
      moveTrackedCopies = 0
      moveTrackedDestroys = 0

      block:
        var payload = MoveTrackedPayload(value: 42,
            state: LiveMoveTrackedPayload)
        emit o.trackedPayloadChanged(move payload)

      check b.value == 42
      check moveTrackedCopies == 0
      check moveTrackedDestroys == 1

    test "grouped sink parameters are flattened through tuple delivery":
      moveTrackedCopies = 0
      moveTrackedDestroys = 0
      connect(o, groupedTrackedPayloadChanged, b, setGroupedTrackedPayload)
      moveTrackedCopies = 0
      moveTrackedDestroys = 0

      block:
        var
          first = MoveTrackedPayload(value: 17, state: LiveMoveTrackedPayload)
          second = MoveTrackedPayload(value: 25, state: LiveMoveTrackedPayload)
        emit o.groupedTrackedPayloadChanged(move first, move second)

      check b.value == 42
      check moveTrackedCopies == 0
      check moveTrackedDestroys == 2

    test "generic sink signals use an explicit tuple type":
      let genericOriginator = GenericOriginator[int]()
      connect(genericOriginator, genericSinkChanged, b, setGenericInt)
      var value = 42
      emit genericOriginator.genericSinkChanged(move value)
      check b.value == 42

      let weakOriginator = genericOriginator.unsafeWeakRef()
      var weakValue = 73
      emit weakOriginator.genericSinkChanged(move weakValue)
      check b.value == 73

    test "ordinary direct fanout does not deep clone identity payloads":
      connect(o, identityChanged, b, setIdentity)
      connect(o, identityChanged, c, setIdentity)
      let payload = IdentityPayload(value: 73)

      emit o.identityChanged(payload)

      check b.value == 73
      check c.value == 73

    test "sink ref fanout retains reference identity":
      connect(o, sinkIdentityChanged, b, setSinkIdentity)
      connect(o, sinkIdentityChanged, c, setSinkIdentity)
      let payload = IdentityPayload(value: 74)

      emit o.sinkIdentityChanged(payload)

      check b.identity == payload
      check c.identity == payload

    test "delivery metadata does not duplicate one handler":
      connect(o, trackedPayloadChanged, b, setTrackedPayload)
      connect(o, trackedPayloadChanged, b, setTrackedPayload(Counter))

      check o.getSubscriptions(sigName"trackedPayloadChanged").toSeq().len() == 1

      var payload = MoveTrackedPayload(value: 38, state: LiveMoveTrackedPayload)
      emit o.trackedPayloadChanged(move payload)
      check b.value == 38

    test "mixed direct fanout clones only movable fields":
      moveTrackedCopies = 0
      moveTrackedDestroys = 0
      connect(o, mixedChanged, b, setMixed)
      connect(o, mixedChanged, c, setMixed)
      moveTrackedCopies = 0
      moveTrackedDestroys = 0
      let identity = IdentityPayload(value: 91)

      block:
        var payload = MoveTrackedPayload(value: 37,
            state: LiveMoveTrackedPayload)
        emit o.mixedChanged(identity, move payload)

      check b.value == 37
      check c.value == 37
      check b.identity == identity
      check c.identity == identity
      check moveTrackedCopies == 1
      check moveTrackedDestroys == 2

    test "signal connect":
      echo "Counter.setValue: ", Counter.setValue().repr
      connect(a, valueChanged, b, setValue)
      connect(a, valueChanged, c, Counter.setValue)
      connect(a, valueChanged, c, setValue Counter)
      check not (compiles(connect(a, someAction, c, Counter.setValue)))

      check b.value == 0
      check c.value == 0
      check d.value == 0

      emit a.valueChanged(137)

      check a.value == 0
      check b.value == 137
      check c.value == 137
      check d.value == 0

      emit a.someChange()
      connect(a, someChange, c, Counter.someAction)

    test "basic signal connect":
      # TODO: how to do this?
      echo "done"
      connect(a, valueChanged, b, setValue)
      connect(a, valueChanged, c, Counter.setValue)

      check a.value == 0
      check b.value == 0
      check c.value == 0

      a.setValue(42)
      check a.value == 42
      check b.value == 42
      check c.value == 42
      echo "TEST REFS: ",
        " aref: ",
        cast[pointer](a).repr,
        " 0x",
        addr(a[]).pointer.repr,
        " agent: 0x",
        addr(Agent(a)).pointer.repr
      check a.unsafeWeakRef().toPtr == cast[pointer](a)
      check a.unsafeWeakRef().toPtr == addr(a[]).pointer

    test "differing agents, same sigs":
      # TODO: how to do this?
      echo "done"
      connect(o, change, b, setValue)

      check b.value == 0

      emit o.change(42)

      check b.value == 42

    test "connect type errors":
      check not compiles(connect(a, avgChanged, c, setValue))

    test "signal connect reg proc":
      # TODO: how to do this?
      static:
        echo "\n\n\nREG PROC"
      # let sv: proc (self: Counter, value: int) = Counter.setValue
      check not compiles(connect(a, valueChanged, b, setSomeValue))

    test "empty signal conversion":
      connect(a, valueChanged, c, someAction, acceptVoidSlot = true)

      check connected(a, valueChanged)
      check not connected(a, someChange)
      check not connected(a, valueChanged, b)
      check connected(a, valueChanged, c)
      check connected(a, valueChanged, c, someAction)
      check not connected(a, valueChanged, b, someAction)
      check not connected(a, valueChanged, c, someOtherAction)

      a.setValue(42)

      check a.value == 42
      check c.avg == -1

    test "test multiarg":
      connect(a, doTick, c, someTick)

      let ts = getMonoTime()
      emit a.doTick(123, ts)

      check c.avg == ts.ticks

    test "subscription lookup finds sorted signal ranges":
      connect(a, valueChanged, b, setValue)
      connect(a, doTick, c, someTick)
      connect(a, valueChanged, d, setValue)
      a.addSubscription(
        AnySigilName,
        b.unsafeWeakRef().asAgent(),
        setValue(Counter)
      )

      check a.subcriptions.len() == 4
      check a.subcriptions[0].signal == AnySigilName
      check a.subcriptions[1].signal == sigName"doTick"
      check a.subcriptions[2].signal == sigName"valueChanged"
      check a.subcriptions[3].signal == sigName"valueChanged"
      check a.getSubscriptions(sigName"valueChanged").toSeq().len() == 3
      check a.getSubscriptions(sigName"doTick").toSeq().len() == 2
      check a.getSubscriptions(sigName"missing").toSeq().len() == 1

    test "test disconnect":
      connect(a, doTick, c, someTick)
      connect(a, doTick, c, someTickOther)
      connect(a, valueChanged, b, setValue)

      check c.listening.len() == 1
      check a.subcriptions.len() == 3
      check a.getSubscriptions(sigName"doTick").toSeq().len() == 2

      printConnections(a)
      printConnections(c)
      disconnect(a, doTick, c, someTick)

      emit a.valueChanged(137)
      echo "afert disconnect"
      printConnections(a)
      printConnections(c)
      check a.value == 0
      check a.subcriptions.len() == 2
      check a.getSubscriptions(sigName"doTick").toSeq().len() == 1
      check b.value == 137
      check c.listening.len() == 1

      let ts = getMonoTime()
      emit a.doTick(123, ts)

      check c.avg == 0

    test "test disconnect all for sig":
      connect(a, doTick, c, someTick)
      connect(a, doTick, c, someTickOther)
      connect(a, valueChanged, b, setValue)

      disconnect(a, doTick, c)

      printConnections(a)
      printConnections(c)
      emit a.valueChanged(137)
      check a.value == 0
      check a.subcriptions.len() == 1
      check a.getSubscriptions(sigName"doTick").toSeq().len() == 0 # maybe?
      check b.value == 137
      check c.listening.len() == 0

      let ts = getMonoTime()
      emit a.doTick(123, ts)

      check c.avg == 0

    test "test multi connect destroyed":
      connect(a, doTick, c, someTick)
      connect(c, doTick, a, someTickOther)
      connect(a, doTick, c, someTickOther)
      connect(a, valueChanged, c, setValue)
      connect(c, valueChanged, a, setValue)

      # printConnections(a)
      # printConnections(c)

    test "test multi connect disconnect without connecting":
      disconnect(a, doTick, c, someTick)
      disconnect(a, doTick, d, someTick)

      # printConnections(a)
      # printConnections(c)

suite "test destroys":
  test "test multi connect disconnect with destroyed":
    var
      b = Counter()

    block:
      var
        awd {.used.} = CounterWithDestroy()

      when defined(sigilsDebug):
        awd.debugName = "AWD"
        b.debugName = "B"
      connect(awd, valueChanged, b, setValue)

      check b.value == 0

      awd.setValue(42)
      check awd.value == 42
      check b.value == 42
      echo "TEST REFS: ",
        " aref: ",
        cast[pointer](awd).repr,
        " 0x",
        addr(awd[]).pointer.repr,
        " agent: 0x",
        addr(Agent(awd)).pointer.repr
      check awd.unsafeWeakRef().toPtr == cast[pointer](awd)
      check awd.unsafeWeakRef().toPtr == addr(awd[]).pointer

    check b.subcriptions.len() == 0
    check b.listening.len() == 0
