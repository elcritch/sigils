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

proc timerRun*(self: Counter) {.slot.} =
  echo "timerRun: ", self.value
  self.value.inc()

suite "connectQueued to local thread":
  test "queued connects a->b on local thread":
    globalCounter = @[]
    startLocalThreadDefault()
    var a = SomeAction()
    var b = Counter()

    block:
      connectQueued(a, valueChanged, b, setValueGlobal)

    emit a.valueChanged(314)
    emit a.valueChanged(139)
    emit a.valueChanged(278)

    # Drain the local thread scheduler to deliver the queued Call
    let ct = getCurrentSigilThread()

    let polled = ct.pollAll()
    check polled == 3
    check globalCounter == @[314, 139, 278]

  test "queued connects a->b on local thread":
    globalCounter = @[]
    startLocalThreadDefault()
    var a = SomeAction()
    var b = Counter()

    block:
      connectQueued(a, valueChanged, b, Counter.setValueGlobal())

    emit a.valueChanged(139)
    emit a.valueChanged(314)
    emit a.valueChanged(278)

    # Drain the local thread scheduler to deliver the queued Call
    let ct = getCurrentSigilThread()

    let polled = ct.pollAll()
    check polled == 3
    check globalCounter == @[139, 314, 278]

  test "timer callback":
    setLocalSigilThread(newSigilAsyncThread())
    let ct = getCurrentSigilThread()
    check ct of AsyncSigilThreadPtr

    var timer = newSigilTimer(duration=initDuration(milliseconds=2))
    var a = Counter()

    connect(timer, timeout, a, Counter.timerRun())

    start(timer)

    ct.poll(NonBlocking)
    check a.value == 0

    for i in 1 .. 10:
      ct.poll()
    check a.value == 10

    cancel(timer)
    ct.poll()

  test "timer callback":
    let ct = getCurrentSigilThread()
    check ct of AsyncSigilThreadPtr

    var timer = newSigilTimer(duration=initDuration(milliseconds=10), count=2)
    var a = Counter()

    connect(timer, timeout, a, Counter.timerRun())

    start(timer)

    ct.poll()
    check a.value == 1
    ct.poll()
    check a.value == 2

    ct.poll()
    check a.value == 2