import std/[unittest, asyncdispatch, times, strutils]
import sigils
import sigils/threadAsyncs

type
  SomeAction* = ref object of Agent
    value: int

  Counter* = ref object of Agent
    value: int

proc valueChanged*(tp: SomeAction, val: int) {.signal.}
proc updated*(tp: Counter, final: int) {.signal.}

## -------------------------------------------------------- ##
let start = epochTime()

proc ticker(self: Counter) {.async.} =
  ## This simple procedure will echo out "tick" ten times with 100ms between
  ## each tick. We use it to visualise the time between other procedures.
  for i in 1 .. 3:
    await sleepAsync(100)
    echo "tick ",
      i * 100, "ms ", split($((epochTime() - start) * 1000), '.')[0], "ms (real)"

  emit self.updated(1337)

proc setValue*(self: Counter, value: int) {.slot.} =
  echo "setValue! ", value, " (th: ", getThreadId(), ")"
  self.value = value
  asyncCheck ticker(self)

proc completed*(self: SomeAction, final: int) {.slot.} =
  echo "Action done! final: ", final, " (th: ", getThreadId(), ")"
  self.value = final

proc value*(self: Counter): int =
  self.value

## -------------------------------------------------------- ##
proc sendBad*(tp: SomeAction, val: Counter) {.signal.}

proc setValueBad*(self: SomeAction, val: Counter) {.slot.} =
  discard

suite "threaded agent slots":
  teardown:
    GC_fullCollect()

  test "sigil object thread runner":
    var
      a = SomeAction()
      b = Counter()

    echo "thread runner!", " (th: ", getThreadId(), ")"
    echo "obj a: ", a.unsafeWeakRef

    let thread = newSigilAsyncThread()
    thread.start()
    startLocalThread()

    let bp: AgentProxy[Counter] = b.moveToThread(thread)
    connect(a, valueChanged, bp, setValue)
    connect(bp, updated, a, SomeAction.completed())

    echo "bp.outbound: ", bp.outbound.AsyncSigilChan.repr
    emit a.valueChanged(314)
    check a.value == 0
    let ct = getCurrentSigilThread()
    ct[].poll()
    check a.value == 1337

  test "sigil object thread bad":
    var
      a = SomeAction()
      b = SomeAction()

    echo "thread runner!", " (th: ", getThreadId(), ")"
    echo "obj a: ", a.unsafeWeakRef

    let thread = newSigilAsyncThread()
    thread.start()
    startLocalThread()

    let bp: AgentProxy[SomeAction] = b.moveToThread(thread)
    check not compiles(connect(a, sendBad, bp, setValueBad))
    # connect(a, sendBad, bp, setValueBad)
