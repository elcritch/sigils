import std/monotimes
import std/strformat
import unittest

import sigils/signals
import sigils/slots
import sigils/core

type
  Emitter = ref object of Agent
  Sink = ref object of Agent
    value: int

proc signal0(tp: Emitter, val: int) {.signal.}
proc signal1(tp: Emitter, val: int) {.signal.}
proc signal2(tp: Emitter, val: int) {.signal.}
proc signal3(tp: Emitter, val: int) {.signal.}
proc signal4(tp: Emitter, val: int) {.signal.}
proc signal5(tp: Emitter, val: int) {.signal.}

proc onSignal0(self: Sink, val: int) {.slot.} =
  self.value += val

proc onSignal1(self: Sink, val: int) {.slot.} =
  self.value += val

proc onSignal2(self: Sink, val: int) {.slot.} =
  self.value += val

proc onSignal3(self: Sink, val: int) {.slot.} =
  self.value += val

proc onSignal4(self: Sink, val: int) {.slot.} =
  self.value += val

proc onSignal5(self: Sink, val: int) {.slot.} =
  self.value += val

method onSignal0Method(self: Agent, val: int) {.base.} =
  discard

method onSignal0Method(self: Sink, val: int) =
  self.value += val

method onSignal1Method(self: Agent, val: int) {.base.} =
  discard

method onSignal1Method(self: Sink, val: int) =
  self.value += val

method onSignal2Method(self: Agent, val: int) {.base.} =
  discard

method onSignal2Method(self: Sink, val: int) =
  self.value += val

method onSignal3Method(self: Agent, val: int) {.base.} =
  discard

method onSignal3Method(self: Sink, val: int) =
  self.value += val

method onSignal4Method(self: Agent, val: int) {.base.} =
  discard

method onSignal4Method(self: Sink, val: int) =
  self.value += val

method onSignal5Method(self: Agent, val: int) {.base.} =
  discard

method onSignal5Method(self: Sink, val: int) =
  self.value += val

const
  signalCount = 6
  slotsPerSignal = 6
  subscriptionCount = signalCount * slotsPerSignal
  n = block:
    when defined(slowbench): 1_000_000
    else: 100_000
  emitCount = n * signalCount
  slotCallCount = n * subscriptionCount
  expectedValue = subscriptionCount * (n * (n - 1) div 2)

var
  durationMicrosDirectProc: float
  durationMicrosMethod: float

proc newSinks(): array[slotsPerSignal, Sink] =
  for idx in 0 ..< slotsPerSignal:
    result[idx] = Sink()

proc newAgentSinks(): array[slotsPerSignal, Agent] =
  for idx in 0 ..< slotsPerSignal:
    result[idx] = Sink()

proc totalValue(sinks: array[slotsPerSignal, Sink]): int =
  for sink in sinks:
    result += sink.value

proc totalAgentValue(sinks: array[slotsPerSignal, Agent]): int =
  for sink in sinks:
    result += Sink(sink).value

proc connectAllSignals(emitter: Emitter, sinks: var array[slotsPerSignal, Sink]) =
  for idx in 0 ..< slotsPerSignal:
    connect(emitter, signal0, sinks[idx], onSignal0)
    connect(emitter, signal1, sinks[idx], onSignal1)
    connect(emitter, signal2, sinks[idx], onSignal2)
    connect(emitter, signal3, sinks[idx], onSignal3)
    connect(emitter, signal4, sinks[idx], onSignal4)
    connect(emitter, signal5, sinks[idx], onSignal5)

template callAllSlotProcs(sinks: typed, val: int) =
  sinks[0].onSignal0(val)
  sinks[1].onSignal0(val)
  sinks[2].onSignal0(val)
  sinks[3].onSignal0(val)
  sinks[4].onSignal0(val)
  sinks[5].onSignal0(val)
  sinks[0].onSignal1(val)
  sinks[1].onSignal1(val)
  sinks[2].onSignal1(val)
  sinks[3].onSignal1(val)
  sinks[4].onSignal1(val)
  sinks[5].onSignal1(val)
  sinks[0].onSignal2(val)
  sinks[1].onSignal2(val)
  sinks[2].onSignal2(val)
  sinks[3].onSignal2(val)
  sinks[4].onSignal2(val)
  sinks[5].onSignal2(val)
  sinks[0].onSignal3(val)
  sinks[1].onSignal3(val)
  sinks[2].onSignal3(val)
  sinks[3].onSignal3(val)
  sinks[4].onSignal3(val)
  sinks[5].onSignal3(val)
  sinks[0].onSignal4(val)
  sinks[1].onSignal4(val)
  sinks[2].onSignal4(val)
  sinks[3].onSignal4(val)
  sinks[4].onSignal4(val)
  sinks[5].onSignal4(val)
  sinks[0].onSignal5(val)
  sinks[1].onSignal5(val)
  sinks[2].onSignal5(val)
  sinks[3].onSignal5(val)
  sinks[4].onSignal5(val)
  sinks[5].onSignal5(val)

template callAllSlotMethods(sinks: typed, val: int) =
  sinks[0].onSignal0Method(val)
  sinks[1].onSignal0Method(val)
  sinks[2].onSignal0Method(val)
  sinks[3].onSignal0Method(val)
  sinks[4].onSignal0Method(val)
  sinks[5].onSignal0Method(val)
  sinks[0].onSignal1Method(val)
  sinks[1].onSignal1Method(val)
  sinks[2].onSignal1Method(val)
  sinks[3].onSignal1Method(val)
  sinks[4].onSignal1Method(val)
  sinks[5].onSignal1Method(val)
  sinks[0].onSignal2Method(val)
  sinks[1].onSignal2Method(val)
  sinks[2].onSignal2Method(val)
  sinks[3].onSignal2Method(val)
  sinks[4].onSignal2Method(val)
  sinks[5].onSignal2Method(val)
  sinks[0].onSignal3Method(val)
  sinks[1].onSignal3Method(val)
  sinks[2].onSignal3Method(val)
  sinks[3].onSignal3Method(val)
  sinks[4].onSignal3Method(val)
  sinks[5].onSignal3Method(val)
  sinks[0].onSignal4Method(val)
  sinks[1].onSignal4Method(val)
  sinks[2].onSignal4Method(val)
  sinks[3].onSignal4Method(val)
  sinks[4].onSignal4Method(val)
  sinks[5].onSignal4Method(val)
  sinks[0].onSignal5Method(val)
  sinks[1].onSignal5Method(val)
  sinks[2].onSignal5Method(val)
  sinks[3].onSignal5Method(val)
  sinks[4].onSignal5Method(val)
  sinks[5].onSignal5Method(val)

template emitAllSignals(emitter: Emitter, val: int) =
  emit emitter.signal0(val)
  emit emitter.signal1(val)
  emit emitter.signal2(val)
  emit emitter.signal3(val)
  emit emitter.signal4(val)
  emit emitter.signal5(val)

suite "multi-signal subscription benchmarks":
  test "slot proc baseline (multi-signal fanout)":
    var sinks = newSinks()

    let t0 = getMonoTime()
    for i in 0 ..< n:
      callAllSlotProcs(sinks, i)
    let dt = getMonoTime() - t0

    check sinks.totalValue == expectedValue

    let us = dt.inMicroseconds.float
    durationMicrosDirectProc = us
    let opsPerSec = (slotCallCount.float * 1_000_000.0) / max(1.0, us)
    echo &"[bench] multi slot proc baseline: n={n}, signals={signalCount}, slotsPerSignal={slotsPerSignal}, subscriptions={subscriptionCount}, slotCalls={slotCallCount}, time={us:.2f} us, rate={opsPerSec:.0f} slot-calls/s, procRatio=1.00"

  test "nim method call (multi-signal fanout)":
    var sinks = newAgentSinks()

    let t0 = getMonoTime()
    for i in 0 ..< n:
      callAllSlotMethods(sinks, i)
    let dt = getMonoTime() - t0

    check sinks.totalAgentValue == expectedValue

    let us = dt.inMicroseconds.float
    durationMicrosMethod = us
    let opsPerSec = (slotCallCount.float * 1_000_000.0) / max(1.0, us)
    echo &"[bench] multi nim method call: n={n}, signals={signalCount}, slotsPerSignal={slotsPerSignal}, subscriptions={subscriptionCount}, slotCalls={slotCallCount}, time={us:.2f} us, rate={opsPerSec:.0f} slot-calls/s, procRatio={us / durationMicrosDirectProc:.2f}"

  test "emit->slot throughput (multi-signal fanout)":
    var emitter = Emitter()
    var sinks = newSinks()
    connectAllSignals(emitter, sinks)

    let t0 = getMonoTime()
    for i in 0 ..< n:
      emitAllSignals(emitter, i)
    let dt = getMonoTime() - t0

    check sinks.totalValue == expectedValue

    let us = dt.inMicroseconds.float
    let ms = dt.inMilliseconds.float
    let opsPerSec = (slotCallCount.float * 1000.0) / max(1.0, ms)
    echo &"[bench] multi emit->slot: n={n}, signals={signalCount}, slotsPerSignal={slotsPerSignal}, subscriptions={subscriptionCount}, emits={emitCount}, slotCalls={slotCallCount}, time={ms:.2f} ms, timeUs={dt.inMicroseconds}, rate={opsPerSec:.0f} slot-calls/s"
    echo &"[bench] multi emit->slot ratios: procRatio={us / durationMicrosDirectProc:.2f}, methodRatio={us / durationMicrosMethod:.2f}"
