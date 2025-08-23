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

var globalCounter: Atomic[int]
globalCounter.store(0)

proc setValueGlobal*(self: Counter, value: int) {.slot.} =
  if self.value != value:
    self.value = value
  globalCounter.store(value)

suite "connectQueued to remote thread":
  test "queued connects a->remote(b) and runs":
    startLocalThread()
    let t = newSigilThread()
    t.start()

    var a = SomeAction()
    var b = Counter()

    let bp: AgentProxy[Counter] = b.moveToThread(t)

    discard threads.connectQueued(a, valueChanged, t, bp.getRemote()[],
        Counter.setValueGlobal)

    emit a.valueChanged(314)

    # Wait briefly for the worker thread to process the Call
    var ok = false
    for i in 0 .. 20:
      if globalCounter.load() == 314:
        ok = true
        break
      os.sleep(20)
    check ok

