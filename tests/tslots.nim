import sigils/signals
import sigils/slots
import sigils/core

import std/monotimes

type
  Counter* = ref object of Agent
    value: int
    avg: int

  Originator* = ref object of Agent

  CounterWithDestroy* = ref object of Agent
    value: int
    avg: int

proc `=destroy`*(x: var typeof(CounterWithDestroy()[])) =
  echo "CounterWithDestroy:destroy: ", x.debugName
  destroyAgent(x)

proc change*(tp: Originator, val: int) {.signal.}

proc valueChanged*(tp: Counter, val: int) {.signal.}
proc valueChanged*(tp: CounterWithDestroy, val: int) {.signal.}

proc someChange*(tp: Counter) {.signal.}

proc avgChanged*(tp: Counter, val: float) {.signal.}

proc setValue*(self: Counter, value: int) {.slot.} =
  echo "setValue! ", value
  if self.value != value:
    self.value = value
    emit self.valueChanged(value)

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
      check SignalTypes.avgChanged(Counter) is (float,)
      check SignalTypes.valueChanged(Counter) is (int,)
      echo "someChange: ", SignalTypes.someChange(Counter).typeof.repr
      check SignalTypes.someChange(Counter) is tuple[]
      check SignalTypes.setValue(Counter) is (int,)

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
