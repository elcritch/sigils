when not defined(sigilsClosures):
  {.error: "tests/tsigilsClosures.nims must define sigilsClosures".}

import std/unittest

import sigils/core
import sigils/closures

import tclosures

type ClosureFlagCounter = ref object of Agent
  value: int
  avg: int

proc valueChanged(self: ClosureFlagCounter, value: int) {.signal.}

suite "agent closure slots (-d:sigilsClosures)":
  test "receiver-bound closure slot captures state and mutates target":
    var
      a = ClosureFlagCounter()
      b = ClosureFlagCounter(value: 100)
      offset = 10

    let conn = connectTo(a, valueChanged, b) do(self: ClosureFlagCounter,
        val: int):
      self.value = val + offset

    emit a.valueChanged(5)
    check b.value == 15

    check conn.disconnect()
    check not conn.disconnect()

    emit a.valueChanged(7)
    check b.value == 15

  test "receiver-bound closure slots keep separate environments":
    var
      a = ClosureFlagCounter()
      b = ClosureFlagCounter()
      first = 2
      second = 3

    let conn1 = connectTo(a, valueChanged, b) do(self: ClosureFlagCounter,
        val: int):
      self.value += val * first

    let conn2 = connectTo(a, valueChanged, b) do(self: ClosureFlagCounter,
        val: int):
      self.avg += val * second

    emit a.valueChanged(4)

    check b.value == 8
    check b.avg == 12

    check conn1.disconnect()
    check conn2.disconnect()
