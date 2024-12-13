import std/isolation
import std/unittest
import std/os

import std/os
import std/monotimes
import std/options
import std/isolation
import std/uri
import std/asyncdispatch

import sigils
import sigils/threads

type SigilsAsyncThread* = ref object of Agent
  thread*: Thread[Chan[ThreadSignal]]
  inputs*: Chan[ThreadSignal]
  trigger*: AsyncEvent

type
  SomeAction* = ref object of Agent
    value: int

  Counter* = ref object of Agent
    value: int

proc newSigilsAsyncThread*(): SigilsAsyncThread =
  result = SigilsAsyncThread()
  result.inputs = newChan[ThreadSignal]()
  result.trigger = newAsyncEvent()

## -------------------------------------------------------- ##

proc valueChanged*(tp: SomeAction, val: int) {.signal.}
proc updated*(tp: Counter, final: int) {.signal.}

proc setValue*(self: Counter, value: int) {.slot.} =
  # echo "setValue! ", value, " (th:", getThreadId(), ")"
  if self.value != value:
    self.value = value
  # echo "Counter: ", self.subscribers
  emit self.updated(self.value)

proc completed*(self: SomeAction, final: int) {.slot.} =
  # echo "Action done! final: ", final, " (th:", getThreadId(), ")"
  self.value = final

proc value*(self: Counter): int =
  self.value

suite "threaded agent slots":
  teardown:
    GC_fullCollect()

  test "sigil object thread runner":
    var
      a = SomeAction.new()
      b = Counter.new()

    # echo "thread runner!", " (th:", getThreadId(), ")"
    # echo "obj a: ", a.unsafeWeakRef
    # echo "obj b: ", b.unsafeWeakRef
    let thread = newSigilThread()
    thread.start()
    startLocalThread()

    let bp: AgentProxy[Counter] = b.moveToThread(thread)
    # echo "obj bp: ", bp.unsafeWeakRef
    # echo "obj bp.remote: ", bp.remote[].unsafeWeakRef

    connect(a, valueChanged, bp, setValue)
    connect(bp, updated, a, SomeAction.completed())

    emit a.valueChanged(314)
    # thread.thread.joinThread(500)
    # os.sleep(500)
    let ct = getCurrentSigilThread()
    ct.poll()
