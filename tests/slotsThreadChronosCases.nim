import std/[times, unittest]

import sigils
import sigils/threadChronos

type
  Source = ref object of AgentActor
    value: int

  Counter = ref object of AgentActor
    value: int

proc valueChanged(source: Source, value: int) {.signal.}
proc updated(counter: Counter, value: int) {.signal.}

proc setValue(counter: Counter, value: int) {.slot.} =
  counter.value = value
  emit counter.updated(value)

proc setCompleted(source: Source, value: int) {.slot.} =
  source.value = value

proc increment(counter: Counter) {.slot.} =
  counter.value.inc()

suite "Chronos-backed Sigils thread":
  test "dispatches threaded signals and wakes promptly":
    let thread = newSigilChronosThread()
    thread.start()
    startLocalThreadDefault()

    var source = Source()
    var counter = Counter()
    var elapsed = 0.0
    block:
      let counterProxy = counter.moveToThread(thread)
      connectThreaded(source, valueChanged, counterProxy, Counter.setValue())
      connectThreaded(counterProxy, updated, source, Source.setCompleted())

      let startedAt = epochTime()
      emit source.valueChanged(42)
      getCurrentSigilThread().poll()
      elapsed = epochTime() - startedAt

    thread.stop()
    thread.join()

    check source.value == 42
    check elapsed < 1.0

  test "uses Chronos timers":
    let thread = newSigilChronosThread()
    var counter = Counter()
    let timer = newSigilTimer(
      duration = initDuration(milliseconds = 5),
      count = 2,
    )
    connect(timer, timeout, counter, Counter.increment())

    thread.setTimer(timer)
    check thread.poll()
    check counter.value == 1
    check thread.poll()
    check counter.value == 2

    thread.stop()
    thread.close()
