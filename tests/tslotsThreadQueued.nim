import std/unittest
import std/os
import threading/atomics

import sigils
import sigils/threads
import sigils/threadAsyncs

type
  SomeAction* = ref object of Agent
    value: int

  Counter* = ref object of Agent
    value: int

  ManagedMessage = object
    label: string
    values: seq[int]

  RefMessage = ref object
    label: string

proc valueChanged*(tp: SomeAction, val: int) {.signal.}
proc messageChanged(source: SomeAction, message: ManagedMessage) {.signal.}
proc refMessageChanged(source: SomeAction, message: RefMessage) {.signal.}

var globalCounter: seq[int]
var globalMessages: seq[ManagedMessage]
var globalRefMessage: RefMessage
var globalRefMessages: seq[RefMessage]

proc setValueGlobal*(self: Counter, value: int) {.slot.} =
  if self.value != value:
    self.value = value
  globalCounter.add(value)

proc receiveMessage(self: Counter, message: ManagedMessage) {.slot.} =
  globalMessages.add(message)

proc receiveRefMessage(self: Counter, message: RefMessage) {.slot.} =
  globalRefMessage = message

proc collectRefMessage(self: Counter, message: RefMessage) {.slot.} =
  globalRefMessages.add(message)

proc timerRun*(self: Counter) {.slot.} =
  self.value.inc()
  echo "timerRun: ", self.value

suite "connectQueued to local thread":
  test "queued connects a->b on local thread":
    globalCounter = @[]
    startLocalThreadDefault()
    var a = SomeAction()
    var b = Counter()

    block:
      connectQueued(a, valueChanged, b, setValueGlobal)

    emit a.valueChanged(314)
    emit a.valueChanged(139)
    emit a.valueChanged(278)

    # Drain the local thread scheduler to deliver the queued Call
    let ct = getCurrentSigilThread()

    let polled = ct.pollAll()
    check polled == 3
    check globalCounter == @[314, 139, 278]

  test "queued connects a->b on local thread":
    globalCounter = @[]
    startLocalThreadDefault()
    var a = SomeAction()
    var b = Counter()

    block:
      connectQueued(a, valueChanged, b, Counter.setValueGlobal())

    emit a.valueChanged(139)
    emit a.valueChanged(314)
    emit a.valueChanged(278)

    # Drain the local thread scheduler to deliver the queued Call
    let ct = getCurrentSigilThread()

    let polled = ct.pollAll()
    check polled == 3
    check globalCounter == @[139, 314, 278]

  test "queued calls own managed payloads":
    globalMessages = @[]
    startLocalThreadDefault()
    let
      source = SomeAction()
      receiver = Counter()

    connectQueued(source, messageChanged, receiver, receiveMessage)

    emit source.messageChanged(ManagedMessage(label: "first", values: @[1, 2]))
    emit source.messageChanged(ManagedMessage(label: "second", values: @[3, 4]))

    let currentThread = getCurrentSigilThread()
    check currentThread.pollAll() == 2
    check globalMessages == @[
      ManagedMessage(label: "first", values: @[1, 2]),
      ManagedMessage(label: "second", values: @[3, 4]),
    ]

  test "queued calls retain references on the local thread":
    globalRefMessage = nil
    startLocalThreadDefault()
    let
      source = SomeAction()
      receiver = Counter()
      message = RefMessage(label: "queued")

    connectQueued(source, refMessageChanged, receiver, receiveRefMessage)
    emit source.refMessageChanged(message)

    let currentThread = getCurrentSigilThread()
    check currentThread.pollAll() == 1
    check globalRefMessage == message

  test "queued fanout retains references for every recipient":
    globalRefMessages = @[]
    startLocalThreadDefault()
    let
      source = SomeAction()
      first = Counter()
      second = Counter()
      message = RefMessage(label: "fanout")

    connectQueued(source, refMessageChanged, first, collectRefMessage)
    connectQueued(source, refMessageChanged, second, collectRefMessage)
    emit source.refMessageChanged(message)

    let currentThread = getCurrentSigilThread()
    check currentThread.pollAll() == 2
    check globalRefMessages.len == 2
    check globalRefMessages[0] == message
    check globalRefMessages[1] == message

  test "timer callback":
    setLocalSigilThread(newSigilAsyncThread())
    let ct = getCurrentSigilThread()
    check ct of AsyncSigilThreadPtr

    var timer = newSigilTimer(duration = initDuration(milliseconds = 2))
    var a = Counter()

    connect(timer, timeout, a, Counter.timerRun())

    start(timer)

    ct.poll(NonBlocking)
    check a.value == 0

    for i in 1 .. 10:
      ct.poll()
    check a.value == 10

    cancel(timer)
    ct.poll()

  test "timer callback":
    let ct = getCurrentSigilThread()
    check ct of AsyncSigilThreadPtr

    var timer = newSigilTimer(duration = initDuration(milliseconds = 10), count = 2)
    var a = Counter()

    connect(timer, timeout, a, Counter.timerRun())

    start(timer)

    ct.poll()
    check a.value == 1
    ct.poll()
    check a.value == 2

    ct.poll()
    check a.value == 2
