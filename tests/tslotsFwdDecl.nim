import sigils/signals
import sigils/slots
import sigils/core
import std/unittest

type
  FwdA* = ref object of Agent
    value: int

proc valueChanged*(tp: FwdA, val: int) {.signal.}

# Forward declare slot without a body
proc onChange*(self: FwdA, val: int) {.slot.}

suite "forward-declared slots":
  test "predeclared slot type compiles and connects":
    var a = FwdA()
    connect(a, valueChanged, a, onChange)

# Implement the slot later
proc onChange*(self: FwdA, val: int) {.slot.} =
  self.value = val

suite "forward-declared slots":
  test "predeclared slot type compiles and connects":
    var a = FwdA()
    connect(a, valueChanged, a, onChange)
    check SignalTypes.onChange(FwdA) is (int, )
    check a.value == 0
    emit a.valueChanged(7)
    check a.value == 7
