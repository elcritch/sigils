import std/isolation
import std/unittest
import std/os

import sigils
import sigils/threads

type
  SomeAction* = ref object of Agent
    value: int

  Counter* = ref object of Agent
    value: int

proc valueChanged*(tp: SomeAction, val: int) {.signal.}

proc setValue*(self: Counter, value: int) {.slot.} =
  echo "setValue! ", value
  if self.value != value:
    self.value = value

proc someAction*(self: Counter) {.slot.} =
  echo "action"

proc value*(self: Counter): int =
  self.value

suite "threaded agent slots":
  teardown:
    GC_fullCollect()

  test "simple threading test":
    var
      a = SomeAction.new()
      b = Counter.new()
      c = Counter.new()

    var agentResults = newChan[(WeakRef[Agent], AgentRequest)]()

    connect(a, valueChanged, b, setValue)
    connect(a, valueChanged, c, Counter.setValue)

    let wa: WeakRef[SomeAction] = a.unsafeWeakRef()
    emit wa.valueChanged(137)
    check typeof(wa.valueChanged(137)) is (WeakRef[Agent], AgentRequest)

    check wa[].value == 0
    check b.value == 137
    check c.value == 137

    proc threadTestProc(aref: WeakRef[SomeAction]) {.thread.} =
      var res = aref.valueChanged(1337)
      echo "Thread aref: ", aref
      echo "Thread sending: ", res
      agentResults.send(unsafeIsolate(ensureMove res))
      echo "Thread Done"

    var thread: Thread[WeakRef[SomeAction]]
    createThread(thread, threadTestProc, wa)
    thread.joinThread()
    let resp = agentResults.recv()
    echo "RESP: ", resp
    emit resp

    check b.value == 1337
    check c.value == 1337
  
  test "sigil object thread runner":
    var
      a = SomeAction.new()
      b = Counter.new()

    echo "thread runner!"
    let thread = newSigilsThread()
    thread.start()
    let bp: AgentProxy[Counter] = b.moveToThread(thread)

    connect(a, valueChanged, bp, setValue)
    connect(a, valueChanged, bp, Counter.setValue())
    check not compiles( connect(a, valueChanged, bp, someAction))

    emit a.valueChanged(314)

    # thread.thread.joinThread(500)
    os.sleep(500)

