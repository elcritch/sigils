import std/[monotimes, os, times, unittest]

import sigils/threadChronos

when defined(windows):
  import std/winlean
else:
  import std/posix

proc processCpuSeconds(): float =
  # times.cpuTime can measure wall time on Windows or just the calling thread
  # on Linux. Include the Chronos worker's CPU usage in the idle measurement.
  when defined(windows):
    var created, exited, kernel, user: FILETIME
    doAssert getProcessTimes(getCurrentProcess(), created, exited, kernel,
        user) != 0
    result = (rdFileTime(kernel) + rdFileTime(user)).float / 10_000_000.0
  else:
    var stamp: Timespec
    doAssert clock_gettime(CLOCK_PROCESS_CPUTIME_ID, stamp) == 0
    result = stamp.tv_sec.float + stamp.tv_nsec.float / 1_000_000_000.0

const
  IdleWarmupMilliseconds = 100
  IdleSampleMilliseconds = 750
  MaximumIdleCpuRatio = 0.20

suite "Chronos thread idle behavior":
  test "does not spin while waiting for work":
    let thread = newSigilChronosThread()
    var
      idleCpuSeconds = 0.0
      idleWallSeconds = 0.0

    thread.start()
    try:
      sleep(IdleWarmupMilliseconds)

      let
        cpuStartedAt = processCpuSeconds()
        wallStartedAt = getMonoTime()
      sleep(IdleSampleMilliseconds)
      idleWallSeconds =
        inNanoseconds(getMonoTime() - wallStartedAt).float / 1_000_000_000.0
      idleCpuSeconds = processCpuSeconds() - cpuStartedAt
    finally:
      thread.stop()
      thread.join()

    let idleCpuRatio = idleCpuSeconds / idleWallSeconds
    checkpoint "idle CPU seconds: " & $idleCpuSeconds
    checkpoint "idle wall seconds: " & $idleWallSeconds
    checkpoint "idle CPU ratio: " & $idleCpuRatio
    check idleWallSeconds >= 0.65
    check idleCpuRatio < MaximumIdleCpuRatio
