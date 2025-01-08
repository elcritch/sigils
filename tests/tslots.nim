import sigils/signals
import sigils/slots
import sigils/core

type
  Counter* = ref object of Agent
    value: int
    avg: int

  Originator* = ref object of Agent

proc change*(tp: Originator, val: int) {.signal.}

proc valueChanged*(tp: Counter, val: int) {.signal.}

proc someChange*(tp: Counter) {.signal.}

proc avgChanged*(tp: Counter, val: float) {.signal.}

proc setValue*(self: Counter, value: int) {.slot.} =
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

proc value*(self: Counter): int =
  self.value

when isMainModule:
  import unittest
  import std/sequtils

  suite "agent slots":
    setup:
      var
        a {.used.} = Counter.new()
        b {.used.} = Counter.new()
        c {.used.} = Counter.new()
        d {.used.} = Counter.new()
        o {.used.} = Originator.new()

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

      a.setValue(42)

      check a.value == 42
      check c.avg == -1

    test "callback creation":
      type
        ClosureRunner[T] = ref object of Agent
          rawEnv: pointer
          rawProc: pointer
          
      proc callClosure[T](self: ClosureRunner[T], value: int) {.slot.} =
        echo "calling closure"
        if self.rawEnv.isNil():
          let c2 = cast[T](self.rawProc)
          c2(value)
        else:
          let c3 = cast[proc (a: int, env: pointer) {.nimcall.}](self.rawProc)
          c3(value, self.rawEnv)

      var
        base = 100

      let
        c1: proc (a: int) =
          proc (a: int) = 
            base = a
        e = c1.rawEnv()
        p = c1.rawProc()
        cc = ClosureRunner[proc (a: int) {.nimcall.}](rawEnv: e, rawProc: p)
      connect(a, valueChanged, cc, ClosureRunner[proc (a: int) {.nimcall.}].callClosure)

      a.setValue(42)

      check a.value == 42
      check base == 42
