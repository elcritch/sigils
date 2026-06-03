import std/monotimes
import std/strformat
import unittest

# Core modules under test
import sigils/signals
import sigils/slots
import sigils/core

when not defined(sigilsCborSerde) and not defined(sigilsJsonSerde):
  import sigils/reactive

#[
Original benchmarks results:
[Suite] benchmarks
[bench] emit->slot: n=20000, time=106.00 ms, rate=188679. ops/s, time=106989 us
  [OK] emit->slot throughput (tight loop)
[bench] slot direct call: n=20000, time=218.00 ms, rate=91743119. ops/s, time=218 us
  [OK] slot direct call (tight loop)
[bench] reactive (lazy): n=20000, time=218.00 ms, rate=91743. iters/s
  [OK] reactive computed (lazy) update+read
[bench] reactive (eager): n=20000, time=181.00 ms, rate=110497. iters/s
  [OK] reactive computedNow eager updates

]#

# Simple Agents for benchmarking
type
  Emitter* = ref object of Agent
  Counter* = ref object of Agent
    value: int

proc bump*(tp: Emitter, val: int) {.signal.}

proc onBump*(self: Counter, val: int) {.slot.} =
  self.value += val

method onBumpMethod*(self: Agent, val: int) {.base.} =
  discard

method onBumpMethod*(self: Counter, val: int) =
  self.value += val

var
  durationMicrosDirectProc: float
  durationMicrosMethod: float

const n = block:
  when defined(slowbench): 10_000_000
  else: 100_000
const expectedValue = (n * (n - 1)) div 2

suite "benchmarks":
  template runBaseline() =
    var b {.inject.} = Counter()

    let t0 = getMonoTime()
    for i in 0 ..< n:
      b.onBump(i)
    let dt = getMonoTime() - t0

    check b.value == expectedValue

    let us {.inject.} = dt.inMicroseconds.float
    durationMicrosDirectProc = us

  for i in 1..10:
    block:
      runBaseLine()

  test "slot proc baseline (tight loop)":
    runBaseLine()
    let opsPerSec = (n.float * 1_000_000.0) / max(1.0, us)
    echo &"[bench] slot proc baseline: n={n}, time={us:.2f} us, rate={opsPerSec:.0f} ops/s, procRatio=1.00"

  test "nim method call (tight loop)":
    var b: Agent = Counter()

    let t0 = getMonoTime()
    for i in 0 ..< n:
      b.onBumpMethod(i)
    let dt = getMonoTime() - t0

    check Counter(b).value == expectedValue

    let us = dt.inMicroseconds.float
    durationMicrosMethod = us
    let opsPerSec = (n.float * 1_000_000.0) / max(1.0, us)
    echo &"[bench] nim method call: n={n}, time={us:.2f} us, rate={opsPerSec:.0f} ops/s, procRatio={us / durationMicrosDirectProc:.2f}"

  test "emit->slot throughput (tight loop)":
    var a = Emitter()
    var b = Counter()

    connect(a, bump, b, onBump)

    let t0 = getMonoTime()
    for i in 0 ..< n:
      emit a.bump(i)
    let dt = getMonoTime() - t0

    check b.value == expectedValue

    let us = dt.inMicroseconds.float
    let ms = dt.inMilliseconds.float
    let opsPerSec = (n.float * 1000.0) / max(1.0, ms)
    echo &"[bench] emit->slot: n={n}, time={ms:.2f} ms, timeUs={dt.inMicroseconds}, rate={opsPerSec:.0f} ops/s"
    echo &"[bench] emit->slot ratios: procRatio={us / durationMicrosDirectProc:.2f}, methodRatio={us / durationMicrosMethod:.2f}"

  when not defined(sigilsCborSerde) and not defined(sigilsJsonSerde):
    test "reactive computed (lazy) update+read":
      let x = newSigil(0)
      let y = computed[int](x{} * 2)

      let t0 = getMonoTime()
      for i in 0 ..< n:
        x <- i
        discard y{} # triggers compute on read when dirty
      let dt = getMonoTime() - t0

      check y{} == (n - 1) * 2

      let ms = dt.inMilliseconds.float
      let itersPerSec = (n.float * 1000.0) / max(1.0, ms)
      echo &"[bench] reactive (lazy): n={n}, time={ms:.2f} ms, rate={itersPerSec:.0f} iters/s"

    test "reactive computedNow eager updates":
      let x = newSigil(0)
      let y = computedNow[int](x{} * 2)

      let t0 = getMonoTime()
      for i in 0 ..< n:
        x <- i # compute happens on set
      let dt = getMonoTime() - t0

      check y{} == (n - 1) * 2

      let ms = dt.inMilliseconds.float
      let itersPerSec = (n.float * 1000.0) / max(1.0, ms)
      echo &"[bench] reactive (eager): n={n}, time={ms:.2f} ms, rate={itersPerSec:.0f} iters/s"
