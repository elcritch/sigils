import std/[monotimes, options, strformat, times, unittest]

import sigils/selectors

type
  SelectorBenchAgent = ref object of DynamicAgent
    value: int

method addSelector(amount: int): int {.selector.}
method pingSelector(): int {.selector.}

proc addDirect(self: SelectorBenchAgent, amount: int): int =
  self.value += amount
  self.value

method addMethodBaseline(self: DynamicAgent, amount: int): int {.base.} =
  discard

method addMethodBaseline(self: SelectorBenchAgent, amount: int): int =
  self.value += amount
  self.value

method addSelectorImpl(self: SelectorBenchAgent,
    amount: int): int {.selector.} =
  self.value += amount
  self.value

method pingSelectorImpl(self: SelectorBenchAgent): int {.selector.} =
  inc self.value
  self.value

const
  n = block:
    when defined(slowbench): 10_000_000
    else: 100_000
  expectedValue = (n * (n - 1)) div 2

var
  directProcMicros: float
  methodMicros: float

template timed(body: untyped): float =
  block:
    let t0 = getMonoTime()
    body
    let dt = getMonoTime() - t0
    dt.inMicroseconds.float

proc reportBench(
    label: string,
    operations: int,
    us: float,
    procBaseline = 0.0,
    methodBaseline = 0.0,
) =
  let rate = (operations.float * 1_000_000.0) / max(1.0, us)
  var line = &"[bench] {label}: n={operations}, time={us:.2f} us, rate={rate:.0f} ops/s"
  if procBaseline > 0.0:
    line.add &", procRatio={us / procBaseline:.2f}"
  if methodBaseline > 0.0:
    line.add &", methodRatio={us / methodBaseline:.2f}"
  echo line

proc newSelectorBenchAgent(): SelectorBenchAgent =
  result = SelectorBenchAgent()
  doAssert result.addMethod(addSelector, addSelectorImpl)
  doAssert result.addMethod(pingSelector, pingSelectorImpl)

suite "selector benchmarks":
  test "direct proc baseline":
    let target = SelectorBenchAgent()
    var last = 0

    let us = timed:
      for i in 0 ..< n:
        last = target.addDirect(i)

    check target.value == expectedValue
    check last == expectedValue

    directProcMicros = us
    reportBench("selector direct proc baseline", n, us)

  test "nim method baseline":
    let target = SelectorBenchAgent()
    var receiver: DynamicAgent = target
    var last = 0

    let us = timed:
      for i in 0 ..< n:
        last = receiver.addMethodBaseline(i)

    check target.value == expectedValue
    check last == expectedValue

    methodMicros = us
    reportBench("selector nim method baseline", n, us, directProcMicros)

  test "required selector send":
    let target = newSelectorBenchAgent()
    var last = 0

    let us = timed:
      for i in 0 ..< n:
        last = target.addSelector(i)

    check target.value == expectedValue
    check last == expectedValue

    reportBench(
      "selector required send",
      n,
      us,
      directProcMicros,
      methodMicros,
    )

  test "perform with var result":
    let target = newSelectorBenchAgent()
    var last = 0

    let us = timed:
      for i in 0 ..< n:
        discard target.perform(addSelector, i, last)

    check target.value == expectedValue
    check last == expectedValue

    reportBench(
      "selector perform var",
      n,
      us,
      directProcMicros,
      methodMicros,
    )

  test "performLocal with var result":
    let target = newSelectorBenchAgent()
    var last = 0

    let us = timed:
      for i in 0 ..< n:
        discard target.performLocal(addSelector, i, last)

    check target.value == expectedValue
    check last == expectedValue

    reportBench(
      "selector performLocal var",
      n,
      us,
      directProcMicros,
      methodMicros,
    )

  test "trySend option result":
    let target = newSelectorBenchAgent()
    var
      handled = 0
      last = 0

    let us = timed:
      for i in 0 ..< n:
        let value = target.trySend(addSelector, i)
        if value.isSome:
          inc handled
          last = value.get()

    check handled == n
    check target.value == expectedValue
    check last == expectedValue

    reportBench(
      "selector trySend option",
      n,
      us,
      directProcMicros,
      methodMicros,
    )

  test "sendIfHandled result discarded":
    let target = newSelectorBenchAgent()
    var handled = 0

    let us = timed:
      for i in 0 ..< n:
        if target.sendIfHandled(addSelector, i):
          inc handled

    check handled == n
    check target.value == expectedValue

    reportBench(
      "selector sendIfHandled",
      n,
      us,
      directProcMicros,
      methodMicros,
    )

  test "zero argument required selector send":
    let target = newSelectorBenchAgent()
    var last = 0

    let us = timed:
      for _ in 0 ..< n:
        last = target.pingSelector()

    check target.value == n
    check last == n

    reportBench(
      "selector zero-arg send",
      n,
      us,
      directProcMicros,
      methodMicros,
    )

  test "responder chain depth one":
    let
      child = SelectorBenchAgent()
      parent = newSelectorBenchAgent()
    child.setNextResponder(parent)
    var last = 0

    let us = timed:
      for i in 0 ..< n:
        discard child.perform(addSelector, i, last)

    check child.value == 0
    check parent.value == expectedValue
    check last == expectedValue

    reportBench(
      "selector responder chain depth 1",
      n,
      us,
      directProcMicros,
      methodMicros,
    )

  test "respondsTo local selector":
    let target = newSelectorBenchAgent()
    var hits = 0

    let us = timed:
      for _ in 0 ..< n:
        if target.respondsTo(addSelector):
          inc hits

    check hits == n

    reportBench("selector respondsTo local", n, us)

  test "localMethod lookup":
    let target = newSelectorBenchAgent()
    var hits = 0

    let us = timed:
      for _ in 0 ..< n:
        if not target.localMethod(addSelector).isNil:
          inc hits

    check hits == n

    reportBench("selector localMethod lookup", n, us)
