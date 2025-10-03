import std/[unittest, times, strutils, os]
import sigils
import sigils/threadSelectors

type
  SomeAction* = ref object of Agent
    value: int

  Counter* = ref object of Agent
    value: int

proc valueChanged*(tp: SomeAction, val: int) {.signal.}
proc updated*(tp: Counter, final: int) {.signal.}
proc updated*(tp: AgentProxy[Counter], final: int) {.signal.}

proc setValue*(self: Counter, value: int) {.slot.} =
  self.value = value
  emit self.updated(1337)

proc setValueNonAsync*(self: Counter, value: int) {.slot.} =
  self.value = value
  emit self.updated(1337)

proc completed*(self: SomeAction, final: int) {.slot.} =
  self.value = final

proc value*(self: Counter): int =
  self.value

suite "threaded agent slots (selectors)":
  teardown:
    GC_fullCollect()

  test "sigil object selectors thread runner":
    var
      a = SomeAction()
      b = Counter()

    let thread = newSigilSelectorThread()
    thread.start()
    startLocalThreadDefault()

    let bp: AgentProxy[Counter] = b.moveToThread(thread)
    connectThreaded(a, valueChanged, bp, setValue)
    connectThreaded(bp, updated, a, SomeAction.completed())

    emit a.valueChanged(314)
    check a.value == 0
    let ct = getCurrentSigilThread()
    discard ct.poll()
    check a.value == 1337

    thread.stop()
    thread.join()

  test "local selectors thread type":
    setLocalSigilThread(newSigilSelectorThread())
    let ct = getCurrentSigilThread()
    check ct of SigilSelectorThreadPtr
    discard ct.poll()
    discard ct.poll(NonBlocking)
    check ct.pollAll() == 0

  test "remote selectors thread trigger using local proxy":
    var a = SomeAction()
    var b = Counter()

    let thread = newSigilSelectorThread()
    thread.start()
    startLocalThreadDefault()

    let bp: AgentProxy[Counter] = b.moveToThread(thread)
    connectThreaded(bp, updated, bp, Counter.setValueNonAsync())
    connectThreaded(bp, updated, a, SomeAction.completed())

    emit bp.updated(1337)

    let ct = getCurrentSigilThread()
    discard ct.poll()
    check a.value == 1337

    thread.stop()
    thread.join()
