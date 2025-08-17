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

import sigils

# framework:
type
  Awsm* = ref object of Agent

# application:
type
  App = ref object of Awsm
    foo: int

proc appEvent(self: Awsm) {.signal.}

proc handling2(self: App) {.slot.}

template replace(self: App, event: typed, handler: typed) =
  disconnect(self, event, self)
  connect(self, event, self, handler)

proc handling1(self: App) {.slot.} =
  self.foo = 1
  replace(self, appEvent, handling2)

proc handling2(self: App) {.slot.} =
  self.foo = 2
  replace(self, appEvent, handling1)

when isMainModule:
  
  let a = App()
  connect(a, appEvent, a, handling1)
  
  emit a.appEvent()
  echo "event1: ",a.foo
  emit a.appEvent()
  echo "event2: ",a.foo
  
  emit a.appEvent()
  echo "event3: ",a.foo
