import sigils/signals
import sigils/slots
import sigils/core
import sigils/closures

import std/sugar

type
  Counter* = ref object of Agent
    value: int
    avg: int

  Originator* = ref object of Agent

proc valueChanged*(tp: Counter, val: int) {.signal.}

proc setValue*(self: Counter, value: int) {.slot.} =
  echo "setValue! ", value
  if self.value != value:
    self.value = value
    emit self.valueChanged(value)

import unittest

suite "agent closure slots":
  test "callback manual creation":
    type ClosureRunner[T] = ref object of Agent
      rawEnv: pointer
      rawProc: pointer

    proc callClosure[T](self: ClosureRunner[T], value: int) {.slot.} =
      echo "calling closure"
      if self.rawEnv.isNil():
        let c2 = cast[T](self.rawProc)
        c2(value)
      else:
        let c3 = cast[proc(a: int, env: pointer) {.nimcall.}](self.rawProc)
        c3(value, self.rawEnv)

    var
      a {.used.} = Counter.new()
      base = 100

    let
      c1: proc(a: int) {.closure.} = proc(a: int) {.closure.} =
        base = a
      e = c1.rawEnv()
      p = c1.rawProc()
      cc = ClosureRunner[proc(a: int) {.nimcall.}](rawEnv: e, rawProc: p)
    connect(a, valueChanged, cc, ClosureRunner[proc(
        a: int) {.nimcall.}].callClosure)

    a.setValue(42)

    check a.value == 42
    check base == 42

  test "callback creation":
    var
      a = Counter()
      b = Counter(value: 100)

    let clsAgent = connectTo(a, valueChanged) do(val: int):
      echo "CLOSURE!"
      b.value = val

    check not compiles(
      connectTo(a, valueChanged) do(val: float):
        b.value = val
    )

    echo "cc3: Type: ", $typeof(clsAgent)
    emit a.valueChanged(42)
    check b.value == 42
    check clsAgent.typeof() is ClosureAgent[(int, )]

  when not defined(sigilsNoClosureSlotEnv):
    test "receiver-bound closure slot captures state and mutates target":
      var
        a = Counter()
        b = Counter(value: 100)
        offset = 10

      let conn = connectTo(a, valueChanged, b) do(self: Counter, val: int):
        self.value = val + offset

      emit a.valueChanged(5)
      check b.value == 15

      check conn.disconnect()
      check not conn.disconnect()

      emit a.valueChanged(7)
      check b.value == 15

    test "receiver-bound closure slots keep separate environments":
      var
        a = Counter()
        b = Counter()
        first = 2
        second = 3

      let conn1 = connectTo(a, valueChanged, b) do(self: Counter, val: int):
        self.value += val * first

      let conn2 = connectTo(a, valueChanged, b) do(self: Counter, val: int):
        self.avg += val * second

      emit a.valueChanged(4)

      check b.value == 8
      check b.avg == 12

      check conn1.disconnect()
      check conn2.disconnect()
