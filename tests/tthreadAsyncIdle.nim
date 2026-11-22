import std/[asyncdispatch, atomics, monotimes, os, times, unittest]
import sigils
import sigils/threadAsyncs

when defined(windows):
  import std/winlean
else:
  import std/posix

type DrainActor = ref object of AgentActor

var followUpQueued: Atomic[bool]

proc requestFollowUp(self: Agent) {.signal.}

proc scheduleFollowUp(self: DrainActor) {.slot.} =
  let worker = cast[AsyncSigilThreadPtr](getCurrentSigilThread())
  callSoon(proc() {.gcsafe.} =
    worker.send(ThreadSignal(kind: Trigger))
    followUpQueued.store(true)
  )

proc processCpuSeconds(): float =
  when defined(windows):
    var created, exited, kernel, user: FILETIME
    doAssert getProcessTimes(getCurrentProcess(), created, exited, kernel,
        user) != 0
    (rdFileTime(kernel) + rdFileTime(user)).float / 10_000_000.0
  else:
    var stamp: Timespec
    doAssert clock_gettime(CLOCK_PROCESS_CPUTIME_ID, stamp) == 0
    stamp.tv_sec.float + stamp.tv_nsec.float / 1_000_000_000.0

suite "async thread idle behavior":
  test "does not spin after processing a wakeup":
    let thread = newSigilAsyncThread()
    thread.start()
    var cpuSeconds, wallSeconds: float
    try:
      thread.send(ThreadSignal(kind: Trigger))
      sleep(100)
      let cpuStart = processCpuSeconds()
      let wallStart = getMonoTime()
      sleep(750)
      wallSeconds = (getMonoTime() - wallStart).inNanoseconds.float / 1_000_000_000.0
      cpuSeconds = processCpuSeconds() - cpuStart
    finally:
      thread.stop()
      thread.join()
    checkpoint "idle CPU ratio: " & $(cpuSeconds / wallSeconds)
    check wallSeconds >= 0.65
    check cpuSeconds / wallSeconds < 0.20

  test "immediate stop wakes the idle dispatcher":
    let thread = newSigilAsyncThread()
    thread.start()
    sleep(100)
    let startedAt = getMonoTime()
    thread.stop(immediate = true)
    thread.join()
    let stopMs = (getMonoTime() - startedAt).inMilliseconds
    checkpoint "stop elapsed milliseconds: " & $stopMs
    check stopMs < 400

  test "drain processes queued signals after stop":
    let thread = newSigilAsyncThread()
    thread.send(ThreadSignal(kind: Trigger))
    thread.stop(drain = true)
    thread.start()
    thread.join()
    check thread.peek() == 0

  test "drain processes signals queued by async callbacks":
    startLocalThreadDefault()
    let thread = newSigilAsyncThread()
    let source = Agent()
    var actor = DrainActor()
    let proxy = actor.moveToThread(thread)
    connectThreaded(source, requestFollowUp, proxy, scheduleFollowUp)
    emit source.requestFollowUp()
    thread.stop(drain = true)
    thread.start()
    thread.join()
    check followUpQueued.load()
    check thread.peek() == 0

  test "immediate stop skips queued signals even if drain is requested":
    let thread = newSigilAsyncThread()
    thread.send(ThreadSignal(kind: Trigger))
    thread.stop(immediate = true, drain = true)
    thread.start()
    thread.join()
    check thread.peek() == 1
