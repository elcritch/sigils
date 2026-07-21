import std/[monotimes, os, times, unittest]

import sigils/threadChronos

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
        cpuStartedAt = cpuTime()
        wallStartedAt = getMonoTime()
      sleep(IdleSampleMilliseconds)
      idleWallSeconds =
        inNanoseconds(getMonoTime() - wallStartedAt).float / 1_000_000_000.0
      idleCpuSeconds = cpuTime() - cpuStartedAt
    finally:
      thread.stop()
      thread.join()

    let idleCpuRatio = idleCpuSeconds / idleWallSeconds
    checkpoint "idle CPU seconds: " & $idleCpuSeconds
    checkpoint "idle wall seconds: " & $idleWallSeconds
    checkpoint "idle CPU ratio: " & $idleCpuRatio
    check idleWallSeconds >= 0.65
    check idleCpuRatio < MaximumIdleCpuRatio
