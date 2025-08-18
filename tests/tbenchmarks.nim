import std/monotimes
import std/strformat
import std/math
import unittest

# Core modules under test
import sigils/signals
import sigils/slots
import sigils/reactive

# Simple Agents for benchmarking
type
  Emitter* = ref object of Agent
  Counter* = ref object of Agent
    value: int

proc bump*(tp: Emitter, val: int) {.signal.}

proc onBump*(self: Counter, val: int) {.slot.} =
  self.value += 1

suite "benchmarks":
  test "emit->slot throughput (tight loop)":
    let n = block:
      when defined(slowbench): 100_000
      elif defined(quickbench): 5_000
      else: 20_000

    var a = Emitter()
    var b = Counter()

    connect(a, bump, b, onBump)

    let t0 = getMonoTime()
    for i in 0 ..< n:
      emit a.bump(i)
    let dt = getMonoTime() - t0

    check b.value == n

    let ms = dt.inMilliseconds.float
    let opsPerSec = (n.float * 1000.0) / max(1.0, ms)
    echo &"[bench] emit->slot: n={n}, time={ms:.2f} ms, rate={opsPerSec:.0f} ops/s"

  test "slot direct call (tight loop)":
    let n = block:
      when defined(slowbench): 100_000
      elif defined(quickbench): 5_000
      else: 20_000

    var a = Emitter()
    var b = Counter()

    let t0 = getMonoTime()
    for i in 0 ..< n:
      b.onBump(i)
    let dt = getMonoTime() - t0

    check b.value == n

    let ms = dt.inMicroseconds.float
    let opsPerSec = (n.float * 1_000_000.0) / max(1.0, ms)
    echo &"[bench] slot direct call: n={n}, time={ms:.2f} ms, rate={opsPerSec:.0f} ops/s"

  test "reactive computed (lazy) update+read":
    let n = block:
      when defined(slowbench): 100_000
      elif defined(quickbench): 5_000
      else: 20_000

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
    let n = block:
      when defined(slowbench): 100_000
      elif defined(quickbench): 5_000
      else: 20_000

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

