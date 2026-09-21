import std/[atomics, isolation, unittest]
import sigils/rchannels

var destroyed: Atomic[int]

type Payload = object
  id: int

proc `=destroy`(payload: Payload) =
  if payload.id != 0:
    discard destroyed.fetchAdd(1)

# A move-only payload with actual managed storage. Every hook can re-enter peek;
# the sink can also fail after cleaning up the source it owns.
type OwnedPayload = object
  id: int
  text: string

var
  ownedObserver: ptr RChan[OwnedPayload]
  ownedDestroyed: array[16, int]
  sinkCalls, movedCalls, destroyCalls: int
  failSink, failAfterSink: bool
  sinkFailureDestination, failedSinkDestination: int

proc `=destroy`(value: OwnedPayload) =
  inc destroyCalls
  if ownedObserver != nil:
    discard ownedObserver[].peek()
  if value.id != 0:
    inc ownedDestroyed[value.id]
  `=destroy`(value.text)

proc `=wasMoved`(value: var OwnedPayload) =
  # Instrument the hook without changing move's noSideEffect contract.
  {.cast(noSideEffect).}:
    inc movedCalls
  value.id = 0
  wasMoved(value.text)

proc `=copy`(dest: var OwnedPayload, src: OwnedPayload) {.error.}
proc `=dup`(src: OwnedPayload): OwnedPayload {.error.}

proc `=sink`(dest: var OwnedPayload, src: OwnedPayload) =
  inc sinkCalls
  if ownedObserver != nil:
    discard ownedObserver[].peek()
  let shouldFail = dest.id == sinkFailureDestination
  if shouldFail and failSink:
    failedSinkDestination = dest.id
    `=destroy`(src)
    raise newException(ValueError, "test sink failure")
  `=destroy`(dest)
  wasMoved(dest)
  dest.id = src.id
  `=sink`(dest.text, src.text)
  if shouldFail and failAfterSink:
    failedSinkDestination = sinkFailureDestination
    raise newException(ValueError, "test failure after sink transfer")

proc ownedPayload(id: int): OwnedPayload =
  OwnedPayload(id: id, text: $id)

proc hookCounts(): tuple[sinks, moves, destroys: int] =
  (sinkCalls, movedCalls, destroyCalls)

type DefaultPayload = object
  id: int = 15
  text: string = "default"

var defaultPayloadsDestroyed: int

proc `=destroy`(value: DefaultPayload) =
  if value.id != 0:
    inc defaultPayloadsDestroyed
  `=destroy`(value.text)

type TeardownPayload = object
  id: int

var
  teardownObserver: ptr RChan[TeardownPayload]
  teardownCalled: bool
  teardownRejected: int

proc `=destroy`(value: TeardownPayload) =
  if value.id != 0 and teardownObserver != nil and not teardownCalled:
    teardownCalled = true
    doAssert teardownObserver[].peek() == 0
    var destination = TeardownPayload(id: 9)
    doAssert not teardownObserver[].tryRecv(destination)
    doAssert destination.id == 9
    var source = isolate(TeardownPayload(id: 2))
    doAssert not teardownObserver[].tryTake(source)
    doAssert extract(source).id == 2
    doAssert not teardownObserver[].trySend(isolate(TeardownPayload(id: 3)))
    try:
      teardownObserver[].send(isolate(TeardownPayload(id: 4)))
    except ValueError:
      inc teardownRejected
    try:
      teardownObserver[].push(isolate(TeardownPayload(id: 5)))
    except ValueError:
      inc teardownRejected
    try:
      teardownObserver[].recv(destination)
    except ValueError:
      inc teardownRejected
    try:
      discard teardownObserver[].recvIso()
    except ValueError:
      inc teardownRejected

const
  ProducerCount = 3
  ConsumerCount = 2
  MessagesPerProducer = 1000
  MessageCount = ProducerCount * MessagesPerProducer

type ThreadMessage = object
  id: int
  text: string

var
  threadChannel: RChan[ThreadMessage]
  delivered: array[MessageCount, Atomic[int]]
  pushChannel: RChan[int]

proc produceMessages(producer: int) {.thread.} =
  {.cast(gcsafe).}:
    for index in 0 ..< MessagesPerProducer:
      let id = producer * MessagesPerProducer + index
      threadChannel.send(isolate(ThreadMessage(id: id, text: $id)))

proc consumeMessages() {.thread.} =
  {.cast(gcsafe).}:
    for _ in 0 ..< MessageCount div ConsumerCount:
      let message = threadChannel.recv()
      doAssert message.id in 0 ..< MessageCount
      doAssert message.text == $message.id
      discard delivered[message.id].fetchAdd(1, moRelaxed)

proc pushMessages() {.thread.} =
  {.cast(gcsafe).}:
    for id in 1 .. 10000:
      pushChannel.push(-id)

proc tryTakeMessages() {.thread.} =
  {.cast(gcsafe).}:
    for id in 1 .. 10000:
      var source = isolate(id)
      if not pushChannel.tryTake(source):
        doAssert extract(source) == id

suite "RChan managed payload ownership":
  test "vacant slots do not construct or return payload field defaults":
    defaultPayloadsDestroyed = 0
    block:
      let empty = newRChan[DefaultPayload](3)
      check empty.peek() == 0
    check defaultPayloadsDestroyed == 0
    block:
      let channel = newRChan[DefaultPayload](3)
      for id in 1 .. 3:
        var source = isolate(DefaultPayload(id: id, text: $id))
        check channel.tryTake(source)
        let empty = extract(source)
        check empty.id == 0
        check empty.text.len == 0
      for id in 1 .. 3:
        var received = channel.recvIso()
        let value = extract(received)
        check value.id == id
        check value.text == $id
    check defaultPayloadsDestroyed == 3

  test "tryRecv destroys received payloads exactly once":
    const iterations = 100
    destroyed.store(0)
    block:
      let channel = newRChan[Payload](1)
      var value: Payload
      for id in 1 .. iterations:
        channel.send(isolate(Payload(id: id)))
        check channel.tryRecv(value)
        check value.id == id
    check destroyed.load() == iterations

  test "recv destroys received payloads exactly once":
    const iterations = 100
    destroyed.store(0)
    block:
      let channel = newRChan[Payload](1)
      for id in 1 .. iterations:
        channel.send(isolate(Payload(id: id)))
        let value = channel.recv()
        check value.id == id
    check destroyed.load() == iterations

  test "recv into a destination destroys the previous value":
    const iterations = 100
    destroyed.store(0)
    block:
      let channel = newRChan[Payload](1)
      var value: Payload
      for id in 1 .. iterations:
        channel.send(isolate(Payload(id: id)))
        channel.recv(value)
        check value.id == id
    check destroyed.load() == iterations

  test "push destroys overwritten payloads":
    destroyed.store(0)
    block:
      let channel = newRChan[Payload](1)
      channel.push(isolate(Payload(id: 1)))
      channel.push(isolate(Payload(id: 2)))
      check channel.recv().id == 2
    check destroyed.load() == 2

  test "the final shared owner destroys unread payloads":
    destroyed.store(0)
    block:
      var retained: RChan[Payload]
      block:
        let channel = newRChan[Payload](1)
        retained = channel
        channel.send(isolate(Payload(id: 1)))
      check destroyed.load() == 0
    check destroyed.load() == 1

  test "tryTake transfers move-only payloads without invoking hooks":
    ownedDestroyed = default(typeof(ownedDestroyed))
    block:
      let channel = newRChan[OwnedPayload](1)
      var source = isolate(ownedPayload(1))
      let before = hookCounts()
      failSink = true
      check channel.tryTake(source)
      failSink = false
      check hookCounts() == before
      check extract(source).id == 0
      var received = channel.recv()
      check received.id == 1
      check received.text == "1"
    check ownedDestroyed[1] == 1

  test "tryTake leaves a full-channel source untouched for retry":
    ownedDestroyed = default(typeof(ownedDestroyed))
    block:
      let channel = newRChan[OwnedPayload](1)
      channel.send(isolate(ownedPayload(1)))
      var source = isolate(ownedPayload(2))
      let before = hookCounts()
      check not channel.tryTake(source)
      check hookCounts() == before
      var first = channel.recv()
      check first.id == 1
      check channel.tryTake(source)
      var second = channel.recv()
      check second.id == 2
      check second.text == "2"
    check ownedDestroyed[1] == 1
    check ownedDestroyed[2] == 1

  test "failed trySend destroys its consumed payload":
    destroyed.store(0)
    block:
      let channel = newRChan[Payload](1)
      channel.send(isolate(Payload(id: 1)))
      check not channel.trySend(isolate(Payload(id: 2)))
      check destroyed.load() == 1
      check channel.recv().id == 1
    check destroyed.load() == 2

  test "recvIso transfers isolated ownership without payload hooks":
    ownedDestroyed = default(typeof(ownedDestroyed))
    block:
      let channel = newRChan[OwnedPayload](1)
      channel.send(isolate(ownedPayload(1)))
      let before = hookCounts()
      failSink = true
      var received = channel.recvIso()
      failSink = false
      check hookCounts() == before
      var value = extract(received)
      check value.id == 1
      check value.text == "1"
    check ownedDestroyed[1] == 1

  test "empty tryRecv preserves a populated destination":
    ownedDestroyed = default(typeof(ownedDestroyed))
    block:
      let channel = newRChan[OwnedPayload](1)
      var destination = ownedPayload(1)
      let sinksBefore = sinkCalls
      check not channel.tryRecv(destination)
      check sinkCalls == sinksBefore
      check destination.id == 1
      check destination.text == "1"
    check ownedDestroyed[1] == 1

  test "overwrite and destination hooks can re-enter the channel":
    ownedDestroyed = default(typeof(ownedDestroyed))
    var channel = newRChan[OwnedPayload](1)
    ownedObserver = addr channel
    block:
      channel.send(isolate(ownedPayload(1)))
      channel.push(isolate(ownedPayload(2)))
      check ownedDestroyed[1] == 1
      var destination = ownedPayload(3)
      channel.recv(destination)
      check destination.id == 2
      check ownedDestroyed[3] == 1
      channel.send(isolate(ownedPayload(4)))
    reset(channel)
    ownedObserver = nil
    for id in 1 .. 4:
      check ownedDestroyed[id] == 1

  test "raising receive sinks release the message and leave capacity usable":
    for useTryRecv in [false, true]:
      for afterTransfer in [false, true]:
        # Check the destination seen by the failing sink, including both an
        # empty destination and replacement of an existing managed payload.
        for destinationId in [0, 2]:
          ownedDestroyed = default(typeof(ownedDestroyed))
          var channel = newRChan[OwnedPayload](1)
          ownedObserver = addr channel
          block:
            channel.send(isolate(ownedPayload(1)))
            var destination: OwnedPayload
            if destinationId != 0:
              destination = ownedPayload(destinationId)
            sinkFailureDestination = destinationId
            failedSinkDestination = -1
            failSink = not afterTransfer
            failAfterSink = afterTransfer
            expect ValueError:
              if useTryRecv:
                discard channel.tryRecv(destination)
              else:
                channel.recv(destination)
            failSink = false
            failAfterSink = false
            check failedSinkDestination == destinationId
            check channel.peek() == 0
            channel.send(isolate(ownedPayload(3)))
            channel.recv(destination)
            check destination.id == 3
            check destination.text == "3"
          reset(channel)
          ownedObserver = nil
          check ownedDestroyed[1] == 1
          check ownedDestroyed[2] == ord(destinationId == 2)
          check ownedDestroyed[3] == 1
    sinkFailureDestination = 0

  test "final-owner cleanup detaches storage and rejects reentrant operations":
    teardownCalled = false
    teardownRejected = 0
    var channel = newRChan[TeardownPayload](1)
    channel.send(isolate(TeardownPayload(id: 1)))
    # Borrow the handle only for the duration of its destructor; do not forge
    # an owning alias or keep the borrow after the channel has been released.
    teardownObserver = addr channel
    reset(channel)
    teardownObserver = nil
    check teardownCalled
    check teardownRejected == 4

suite "RChan fixed ring":
  test "FIFO order and overwrite wrap around arbitrary capacities":
    for capacity in [1, 3, 7]:
      let channel = newRChan[string](capacity)
      for round in 0 ..< 20:
        let offset = round * (capacity + 1)
        for index in 0 ..< capacity:
          channel.send($(offset + index))
        check channel.recv() == $offset
        channel.send($(offset + capacity))
        channel.push($(offset + capacity + 1))
        check channel.peek() == capacity
        for index in 2 .. capacity + 1:
          check channel.recv() == $(offset + index)
        check channel.peek() == 0

  test "multiple producers and consumers deliver each managed message once":
    for capacity in [1, 7]:
      for count in delivered.mitems:
        count.store(0)
      threadChannel = newRChan[ThreadMessage](capacity)
      var producers: array[ProducerCount, Thread[int]]
      var consumers: array[ConsumerCount, Thread[void]]
      for index in 0 ..< ProducerCount:
        createThread(producers[index], produceMessages, index)
      for index in 0 ..< ConsumerCount:
        createThread(consumers[index], consumeMessages)
      joinThreads(producers)
      joinThreads(consumers)
      for count in delivered.mitems:
        check count.load() == 1
      check threadChannel.peek() == 0
      reset(threadChannel)

  test "concurrent push and tryTake preserve rejected sources":
    pushChannel = newRChan[int](3)
    var producer, taker: Thread[void]
    createThread(producer, pushMessages)
    createThread(taker, tryTakeMessages)
    joinThread(producer)
    joinThread(taker)
    check pushChannel.peek() == 3
    reset(pushChannel)

when not defined(useMalloc):
  proc createEmptyChannel() =
    let channel = newRChan[int](1)
    doAssert channel.peek() == 0

  suite "RChan storage ownership":
    test "empty channel lifetimes release all ring allocations":
      createEmptyChannel()
      let before = getOccupiedMem()
      for _ in 0 ..< 10000:
        createEmptyChannel()
      let growth = getOccupiedMem() - before
      check growth == 0

when defined(linux):
  import std/strutils

  proc rssKb(): int64 =
    for line in lines("/proc/self/status"):
      if line.startsWith("VmRSS:"):
        let fields = line.splitWhitespace()
        if fields.len >= 2:
          return parseInt(fields[1]).int64
    raise newException(IOError, "unable to read VmRSS from /proc/self/status")

elif defined(macosx):
  type
    MachPort = uint32
    MachMsgTypeNumber = uint32
    TimeValue = object
      seconds: int32
      microseconds: int32

    MachTaskBasicInfo = object
      virtualSize: uint64
      residentSize: uint64
      residentSizeMax: uint64
      userTime: TimeValue
      systemTime: TimeValue
      policy: int32
      suspendCount: int32

  const machTaskBasicInfoFlavor = 20

  var machTaskSelf {.importc: "mach_task_self_", header: "<mach/mach_init.h>".}:
    MachPort

  proc taskInfo(
    task: MachPort,
    flavor: cint,
    taskInfoOut: ptr MachTaskBasicInfo,
    taskInfoOutCount: ptr MachMsgTypeNumber,
  ): cint {.importc: "task_info", header: "<mach/task.h>".}

  proc rssKb(): int64 =
    var info: MachTaskBasicInfo
    var count = MachMsgTypeNumber(sizeof(MachTaskBasicInfo) div sizeof(cuint))
    let status = taskInfo(machTaskSelf, machTaskBasicInfoFlavor, addr info, addr count)
    doAssert status == 0, "task_info failed with kern_return_t " & $status
    int64(info.residentSize div 1024)

when defined(linux) or defined(macosx):
  const
    RssSampleCount = 6
    RssIterationsPerSample = 64
    RssPayloadSize = 512 * 1024
    RssMaxGrowthKb = 64 * 1024

  proc median3(a, b, c: int64): int64 =
    a + b + c - min(a, min(b, c)) - max(a, max(b, c))

  proc newRssPayload(size: int): string =
    result = newString(size)
    var index = 0
    while index < size:
      result[index] = 'x'
      inc index, 4096
    result[^1] = 'x'

  proc drainChannel(iterations, payloadSize: int, useTryRecv: bool): bool =
    let channel = newRChan[string](1)
    var value: string
    for _ in 0 ..< iterations:
      channel.send(isolate(newRssPayload(payloadSize)))
      if useTryRecv:
        if not channel.tryRecv(value):
          return false
      else:
        channel.recv(value)
    true

  proc rchanRssGrowth(useTryRecv: bool): int64 =
    var samples: array[RssSampleCount, int64]
    for index in 0 ..< RssSampleCount:
      doAssert drainChannel(RssIterationsPerSample, RssPayloadSize, useTryRecv)
      samples[index] = rssKb()
    let early = median3(samples[0], samples[1], samples[2])
    let late = median3(samples[3], samples[4], samples[5])
    max(0'i64, late - early)

  suite "RChan managed payload RSS":
    test "tryRecv does not retain managed payloads":
      check rchanRssGrowth(useTryRecv = true) <= RssMaxGrowthKb

    test "recv does not retain managed payloads":
      check rchanRssGrowth(useTryRecv = false) <= RssMaxGrowthKb

