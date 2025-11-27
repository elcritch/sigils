import std/[unittest, times, net, strutils, os, posix]
import sigils
import sigils/threadSelectors

type
  SomeAction* = ref object of Agent
    value: int

  Counter* = ref object of Agent
    value: int

  DataWatcher* = ref object of Agent
    hits: int

proc valueChanged*(tp: SomeAction, val: int) {.signal.}
proc updated*(tp: Counter, final: int) {.signal.}
proc updates*(tp: AgentProxy[Counter], final: int) {.signal.}

proc setValue*(self: Counter, value: int) {.slot.} =
  echo "setValue: ", value, " (" & $getThreadId() & ")"
  self.value = value
  emit self.updated(value)

proc timerRun*(self: Counter) {.slot.} =
  self.value.inc()
  echo "timeout! value: ", self.value
  emit self.updated(self.value)

proc completed*(self: SomeAction, final: int) {.slot.} =
  echo "completed: ", final, " (" & $getThreadId() & ")"
  self.value = final

proc value*(self: Counter): int =
  self.value

proc onReady*(self: DataWatcher) {.slot.} =
  self.hits.inc()

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
    check a.value == 314

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
    connectThreaded(a, valueChanged, bp, Counter.setValue())

    check Counter(bp.remote[]).value == 0
    emit a.valueChanged(1337)

    let ct = getCurrentSigilThread()
    discard ct.poll()
    for i in 1..10:
      os.sleep(100)
      echo "test... value: ", Counter(bp.remote[]).value
      if Counter(bp.remote[]).value != 0:
        break

    check Counter(bp.remote[]).value == 1337

    thread.stop()
    thread.join()

  test "local selectors thread timer":
    setLocalSigilThread(newSigilSelectorThread())
    let ct = getCurrentSigilThread()
    check ct of SigilSelectorThreadPtr

    var timer = newSigilTimer(duration = initDuration(milliseconds = 2))
    var a = Counter()
    connect(timer, timeout, a, Counter.timerRun())

    start(timer)

    discard ct.poll(NonBlocking)
    check a.value == 0

    for i in 1 .. 100:
      discard ct.poll()
      os.sleep(2)
      if a.value >= 1: break
    check a.value >= 1

    cancel(timer)
    discard ct.poll()

  test "remote selectors thread timer":
    var b = Counter()

    let thread = newSigilSelectorThread()
    thread.start()
    startLocalThreadDefault()

    let bp: AgentProxy[Counter] = b.moveToThread(thread)

    var timer = newSigilTimer(duration = initDuration(milliseconds = 10), count = 2)
    connectThreaded(timer, timeout, bp, Counter.timerRun())
    start(timer, thread)

    let ct = getCurrentSigilThread()
    # Drain local default thread to deliver remote->local proxy Trigger events
    for i in 0 .. 20:
      discard ct.poll()
      os.sleep(10)

    check Counter(bp.remote[]).value >= 2

    cancel(timer, thread)
    thread.stop()
    thread.join()

  test "selectors dataReady for socket handle":
    ## Verify that registering a SigilDataReady with the selector
    ## results in a dataReady signal when the underlying socket
    ## becomes readable.
    setLocalSigilThread(newSigilSelectorThread())
    let ct = getCurrentSigilThread()
    check ct of SigilSelectorThreadPtr

    let st = SigilSelectorThreadPtr(ct)

    var fds: array[0..1, cint]
    let res = socketpair(AF_UNIX, SOCK_STREAM, 0.cint, fds)
    check res == 0

    var watcher = DataWatcher()
    var ready = newSigilDataReady(st, fds[0].int)

    connect(ready, dataReady, watcher, DataWatcher.onReady())

    # No data written yet; polling should not trigger the watcher.
    discard ct.poll(NonBlocking)
    check watcher.hits == 0

    let msg = "hello"
    let written = write(fds[1], cast[pointer](msg.cstring), msg.len)
    check written == msg.len

    var attempts = 0
    while watcher.hits == 0 and attempts < 50:
      discard ct.poll()
      os.sleep(2)
      attempts.inc()

    check watcher.hits >= 1

    discard close(fds[0])
    discard close(fds[1])

  test "selectors dataReady for readable socket":
    setLocalSigilThread(newSigilSelectorThread())
    let ct = getCurrentSigilThread()
    check ct of SigilSelectorThreadPtr
    let st = SigilSelectorThreadPtr(ct)

    var sock = newSocket()
    var ready = newSigilDataReady(st, sock)

