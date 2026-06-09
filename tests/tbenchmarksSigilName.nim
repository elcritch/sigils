import std/[algorithm, monotimes, strformat, tables]
import std/unittest

import sigils

const
  n = block:
    when defined(slowbench):
      3_000_000
    else:
      300_000

  sourceCount = block:
    when defined(slowbench):
      50_000
    else:
      5_000

  copyIterations = block:
    when defined(slowbench):
      50_000
    else:
      5_000

proc ratePerSecond(ops: int, us: int64): float =
  if us > 0:
    (ops.float * 1_000_000.0) / us.float
  else:
    0.0

proc millis(us: int64): float =
  us.float / 1000.0

suite "SigilName benchmarks":
  test "toSigilName conversion from short payloads":
    var source = newSeq[string](sourceCount)
    for i in 0 ..< sourceCount:
      source[i] = "sigil_" & $i

    var converted = newSeq[SigilName](sourceCount)
    var checksum = 0

    let t0 = getMonoTime()
    for i in 0 ..< n:
      let idx = i mod sourceCount
      converted[idx] = toSigilName(source[idx])
      checksum += converted[idx].len
    let dt = getMonoTime() - t0

    check checksum > 0
    let us = dt.inMicroseconds
    echo &"[bench] toSigilName conversion: n={n}, time={millis(us):.2f} ms, rate={ratePerSecond(n, us):.0f} ops/s"

  test "compareSigilName with near-hit comparisons":
    var names = newSeq[SigilName](sourceCount)
    for i in 0 ..< sourceCount:
      names[i] = toSigilName("sigil_" & $i)

    var score = 0
    let t0 = getMonoTime()
    for i in 0 ..< n:
      let left = names[i mod sourceCount]
      let right = names[(i * 31 + 7) mod sourceCount]
      if compareSigilName(left, right) < 0:
        inc score
    let dt = getMonoTime() - t0

    check score >= 0
    let us = dt.inMicroseconds
    let usPerOp = if n > 0: us.float / n.float else: 0.0
    echo &"[bench] compareSigilName: n={n}, time={millis(us):.2f} ms, rate={ratePerSecond(n, us):.0f} ops/s, usPerOp={usPerOp:.3f}"

  test "table insert and lookup with SigilName keys":
    var lookup = newSeq[SigilName](sourceCount)
    for i in 0 ..< sourceCount:
      lookup[i] = toSigilName("sigil_" & $i)

    var table = initTable[SigilName, int](sourceCount * 2)

    let insertStart = getMonoTime()
    for i in 0 ..< sourceCount:
      table[lookup[i]] = i
    let insertDur = getMonoTime() - insertStart

    var sum = 0
    let lookupStart = getMonoTime()
    for i in 0 ..< n:
      sum += table[lookup[i mod sourceCount]]
    let lookupDur = getMonoTime() - lookupStart

    check sum >= 0
    let insUs = insertDur.inMicroseconds
    let lookupUs = lookupDur.inMicroseconds
    echo &"[bench] SigilName table insert: n={sourceCount}, time={millis(insUs):.2f} ms, rate={ratePerSecond(sourceCount, insUs):.0f} ops/s"
    echo &"[bench] SigilName table lookup: n={n}, time={millis(lookupUs):.2f} ms, rate={ratePerSecond(n, lookupUs):.0f} ops/s"

  test "copy overhead (assignment + sort by comparator)":
    var values = newSeq[SigilName](sourceCount)
    for i in 0 ..< sourceCount:
      values[i] = toSigilName("sigil_" & $i)

    var copied: seq[SigilName]
    let copyStart = getMonoTime()
    for i in 0 ..< copyIterations:
      copied = values
    let copyDur = getMonoTime() - copyStart

    let copyUs = copyDur.inMicroseconds
    let copiedBytes = copyIterations.float * sourceCount.float * sizeof(
        SigilName).float
    echo &"[bench] SigilName seq assignment: n={copyIterations}, bytesTouched~{copiedBytes:.0f}, time={millis(copyUs):.2f} ms, rate={ratePerSecond(copyIterations, copyUs):.0f} copies/s"

    if copied.len > 0:
      let sortStart = getMonoTime()
      copied.sort(
        proc(a, b: SigilName): int =
        compareSigilName(a, b)
      )
      let sortDur = getMonoTime() - sortStart
      let sortUs = sortDur.inMicroseconds
      echo &"[bench] SigilName sort: n={copied.len}, time={millis(sortUs):.2f} ms"
