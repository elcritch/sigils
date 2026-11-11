import std/[monotimes, os, times, unittest]
import sigils/[core, threadAsyncs]

when defined(windows):
  import std/winlean
else:
  import std/posix

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
