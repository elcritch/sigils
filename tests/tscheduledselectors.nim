import std/[monotimes, os, times, unittest]
import sigils/[scheduledselectors, selectors, threadAsyncs, threadDefault]
from sigils/agents import AgentEndpoint, endpoint, isAlive

type Counter = ref object of DynamicAgent
  value: int

type TimerOwner = ref object of DynamicAgent
  send: ScheduledSend
  cancelled: bool

protocol CounterProtocol from Counter:
  method change(self: Counter, amount: int) =
    self.value += amount

  method assign(self: Counter, value: int, offset: int = 1) =
    self.value = value + offset

  method copyValue(self: Counter, source: Counter) =
    self.value = source.value

  method current(self: Counter): int =
    self.value

template pollUntil(condition: untyped) =
  let deadline = getMonoTime() + initDuration(seconds = 5)
  while not condition and getMonoTime() < deadline:
    getCurrentSigilThread().poll(NonBlocking)
    sleep(1)
  require condition

suite "scheduled selector sends":
  test "queued commands run on poll":
    startLocalThreadDispatch()
    let counter = Counter().withProto()
    counter.sendLater(change(3))
    check counter.value == 0
    getCurrentSigilThread().poll()
    check counter.value == 3

  test "delayed command runs on timer":
    let counter = Counter().withProto()
    counter.sendAfter(initDuration(milliseconds = 1), change(4))
    check counter.value == 0
    pollUntil(counter.value != 0)
    check counter.value == 4

  test "cancelled timer does not send":
    let counter = Counter().withProto()
    proc cancelDelayedChange(receiver: Counter) {.gcsafe.} =
      let scheduled = receiver.sendAfter(initDuration(milliseconds = 1), change(8))
      scheduled.cancel()
      scheduled.cancel()

    cancelDelayedChange(counter)
    require getCurrentSigilThread().toCancel.len == 1
    pollUntil(getCurrentSigilThread().toCancel.len == 0)
    check counter.value == 0

  test "delayed sends skip a destroyed receiver":
    proc scheduleCopy(): tuple[receiver, source: AgentEndpoint, pending: ScheduledSend] =
      let receiver = Counter().withProto()
      let source = Counter(value: 7)
      let pending =
        receiver.sendAfter(initDuration(milliseconds = 1), copyValue(source))
      (receiver.endpoint(), source.endpoint(), pending)

    let copy = scheduleCopy()
    require not copy.receiver.isAlive
    require copy.source.isAlive
    pollUntil(not copy.source.isAlive)
    copy.pending.cancel()

  test "queued sends follow the responder chain":
    let source = Counter()
    let responder = Counter().withProto()
    source.setNextResponder(responder)
    source.sendLater(change(9))
    getCurrentSigilThread().poll()
    check responder.value == 9

  test "queued command skips a destroyed receiver":
    proc queueCopy(): tuple[receiver, source: AgentEndpoint] =
      let receiver = Counter().withProto()
      let source = Counter(value: 3)
      receiver.sendLater(copyValue(source))
      (receiver.endpoint(), source.endpoint())

    let copy = queueCopy()
    require not copy.receiver.isAlive
    require copy.source.isAlive
    getCurrentSigilThread().poll(NonBlocking)
    check not copy.source.isAlive

  test "selector arguments are evaluated once":
    let counter = Counter().withProto()
    var evaluated = 0
    proc amount(): int =
      inc evaluated
      2

    counter.sendLater(change(amount()))
    check evaluated == 1
    getCurrentSigilThread().poll()
    check counter.value == 2
    check evaluated == 1

  test "typed selectors and call-form defaults preserve arguments":
    let counter = Counter().withProto()
    counter.sendLater(assign(value = 4))
    getCurrentSigilThread().poll()
    check counter.value == 5
    enqueueSelector(counter, change(), 3)
    getCurrentSigilThread().poll()
    check counter.value == 8
    check not compiles(counter.sendLater(current()))

  test "negative delays are rejected":
    let counter = Counter().withProto()
    expect ValueError:
      counter.sendAfter(initDuration(milliseconds = -1), change(1))

  test "default scheduler rejects delayed sends":
    let previous = getCurrentSigilThread()
    let local = newSigilThread()
    setLocalSigilThread(local)
    try:
      let counter = Counter().withProto()
      expect ValueError:
        counter.sendAfter(initDuration(milliseconds = 1), change(1))
      counter.sendLater(change(2))
      check counter.value == 0
      local.toSigilThread().poll()
      check counter.value == 2
    finally:
      setLocalSigilThread(previous)

  test "host timers deliver once and cancel on the default scheduler":
    let previous = getCurrentSigilThread()
    let local = newSigilThread()
    setLocalSigilThread(local)
    defer:
      setLocalSigilThread(previous)

    let delay = initDuration(milliseconds = 120)
    var fire: SelectorTimerCallback
    var cancellations = 0
    proc armTimer(
        wait: Duration, callback: SelectorTimerCallback
    ): SelectorTimerCancellation =
      check wait == delay
      fire = callback
      result = proc() =
        inc cancellations

    let counter = Counter().withProto()
    let cancelled = counter.sendAfter(delay, change(3), armTimer)
    cancelled.cancel()
    cancelled.cancel()
    check cancellations == 1
    fire()
    check counter.value == 0

    counter.sendAfter(delay, change(2), armTimer)
    check counter.value == 0
    fire()
    fire()
    check counter.value == 2

    proc failToArm(
        wait: Duration, callback: SelectorTimerCallback
    ): SelectorTimerCancellation =
      fire = callback
      raise newException(ValueError, "timer registration failed")

    expect ValueError:
      counter.sendAfter(delay, change(9), failToArm)
    fire()
    check counter.value == 2

    proc scheduleForTemporaryReceiver(): AgentEndpoint =
      let temporary = Counter().withProto()
      temporary.sendAfter(delay, change(5), armTimer)
      temporary.endpoint()

    let temporary = scheduleForTemporaryReceiver()
    require not temporary.isAlive
    fire()

  test "host timer delivery releases its cancellation context":
    var fire: SelectorTimerCallback
    let delay = initDuration(milliseconds = 120)
    let counter = Counter().withProto()
    proc registerTimer(): AgentEndpoint =
      let owner = TimerOwner()
      proc armTimer(
          wait: Duration, callback: SelectorTimerCallback
      ): SelectorTimerCancellation =
        fire = callback
        result = proc() =
          owner.cancelled = true

      owner.send = counter.sendAfter(delay, change(4), armTimer)
      owner.endpoint()

    let owner = registerTimer()
    require owner.isAlive
    fire()
    check not owner.isAlive
    check counter.value == 4
