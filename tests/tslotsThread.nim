import std/isolation
import std/unittest
import std/os

import sigils
import sigils/threads

type Counter* = ref object of Agent
  value: int
  avg: int

proc valueChanged*(tp: Counter, val: int) {.signal.}

proc setValue*(self: Counter, value: int) {.slot.} =
  echo "setValue! ", value
  if self.value != value:
    self.value = value
  emit self.valueChanged(value)

proc someAction*(self: Counter) {.slot.} =
  echo "action"

proc value*(self: Counter): int =
  self.value

suite "threaded agent slots":
  setup:
    var
      a {.used.} = Counter.new()
      b {.used.} = Counter.new()
      c {.used.} = Counter.new()

  teardown:
    GC_fullCollect()

  test "simple threading test":
    var agentResults = newChan[(WeakRef[Agent], AgentRequest)]()

    connect(a, valueChanged, b, setValue)
    connect(a, valueChanged, c, Counter.setValue)
    connect(a, valueChanged, c, setValue Counter)

    let wa: WeakRef[Counter] = a.unsafeWeakRef()
    emit wa.valueChanged(137)
    check typeof(wa.valueChanged(137)) is (WeakRef[Agent], AgentRequest)

    check wa[].value == 0
    check b.value == 137
    check c.value == 137

    proc threadTestProc(aref: WeakRef[Counter]) {.thread.} =
      var res = aref.valueChanged(1337)
      echo "Thread aref: ", aref
      echo "Thread sending: ", res
      agentResults.send(unsafeIsolate(ensureMove res))
      echo "Thread Done"

    var thread: Thread[WeakRef[Counter]]
    createThread(thread, threadTestProc, wa)
    thread.joinThread()
    let resp = agentResults.recv()
    echo "RESP: ", resp
    emit resp

    check b.value == 1337
    check c.value == 1337
  
  test "sigil object thread runner":
    echo "thread runner!"
    let thread = newSigilsThread()
    thread.start()
    let bp: AgentProxy[Counter] = b.moveToThread(thread)

    connect(a, valueChanged, bp, setValue)
    check not compiles(
        connect(a, valueChanged, bp, someAction)
    )
    connect(a, valueChanged, bp, Counter.setValue())

    emit a.valueChanged(314)

    # thread.thread.joinThread(500)
    os.sleep(1_000)

