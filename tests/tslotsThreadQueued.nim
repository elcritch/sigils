import std/unittest
import std/os
import threading/atomics

import sigils
import sigils/threads

type
  SomeAction* = ref object of Agent
    value: int

  Counter* = ref object of Agent
    value: int

proc valueChanged*(tp: SomeAction, val: int) {.signal.}

var globalCounter: seq[int]

proc setValueGlobal*(self: Counter, value: int) {.slot.} =
  if self.value != value:
    self.value = value
  globalCounter.add(value)

suite "connectQueued to local thread":
  test "queued connects a->b on local thread":
    startLocalThread()
    var a = SomeAction()
    var b = Counter()

    connectQueued(a, valueChanged, b, setValueGlobal)

    emit a.valueChanged(314)
    emit a.valueChanged(139)
    emit a.valueChanged(278)

    # Drain the local thread scheduler to deliver the queued Call
    let ct = getCurrentSigilThread()

    let polled = ct[].pollAll()
    check polled == 3
    check globalCounter == @[314, 139, 278]

  # test "queued connects a->b on local thread":
  #   startLocalThread()
  #   var a = SomeAction()
  #   var b = Counter()

  #   block:
  #     discard threads.connectQueued(a, valueChanged, b, Counter.setValueGlobal)

  #   emit a.valueChanged(314)
  #   emit a.valueChanged(139)
  #   emit a.valueChanged(278)

  #   # Drain the local thread scheduler to deliver the queued Call
  #   let ct = getCurrentSigilThread()

  #   let polled = ct[].pollAll()
  #   check polled == 3
  #   check globalCounter == @[314, 139, 278]

