import std/[locks, os, unittest]
import threading/atomics

import sigils
import sigils/registry
import sigils/threads

type
  PoolSource = ref object of AgentActor

  PoolCounter = ref object of AgentActor
    value: int

proc valueChanged*(self: PoolSource, value: int) {.signal.}
proc ping*(self: AgentProxy[PoolCounter], value: int) {.signal.}
proc pong*(self: PoolCounter, value: int) {.signal.}

var inSlot: Atomic[int]
var maxInSlot: Atomic[int]
var seenCount: Atomic[int]
var doneCount: Atomic[int]
var workerIds: array[8, int]
var workerCount: int
var releaseWorkers: Atomic[bool]
var localValue: Atomic[int]
var stressLock: Lock
var stressDone: int
var stressSum: int

stressLock.initLock()

proc rememberWorker() =
  withLock stressLock:
    let id = getThreadId()
    for index in 0 ..< workerCount:
      if workerIds[index] == id:
        return
    doAssert workerCount < workerIds.len
    workerIds[workerCount] = id
    workerCount.inc()

proc countWorkers(): int =
  withLock stressLock:
    result = workerCount

proc setValue*(self: PoolCounter, value: int) {.slot.} =
  let now = inSlot.fetchAdd(1) + 1
  var previous = maxInSlot.load()
  while previous < now and not maxInSlot.compareExchange(previous, now):
    discard
  rememberWorker()
  os.sleep(1)
  self.value = value
  seenCount.atomicInc()
  discard inSlot.fetchSub(1)
  emit self.pong(value)

proc setValueSlow*(self: PoolCounter, value: int) {.slot.} =
  discard inSlot.fetchAdd(1)
  rememberWorker()
  os.sleep(40)
  self.value = value
  doneCount.atomicInc()
  discard inSlot.fetchSub(1)

proc waitForRelease(self: PoolCounter, value: int) {.slot.} =
  rememberWorker()
  while not releaseWorkers.load():
    os.sleep(1)
  doneCount.atomicInc()

proc localDone*(self: PoolCounter, value: int) {.slot.} =
  localValue.store(value)

proc setValueStress*(self: PoolCounter, value: int) {.slot.} =
  rememberWorker()
  self.value = value
  withLock stressLock:
    stressDone.inc()
    stressSum.inc(value)

proc waitFor(target: proc(): bool {.gcsafe.}, attempts = 2_000) =
  for _ in 1 .. attempts:
    if target():
      return
    os.sleep(1)

suite "thread pool":
  setup:
    inSlot.store(0)
    maxInSlot.store(0)
    seenCount.store(0)
    doneCount.store(0)
    releaseWorkers.store(false)
    localValue.store(0)
    withLock stressLock:
      workerCount = 0
      stressDone = 0
      stressSum = 0
    startLocalThreadDefault()

  test "single actor serialization":
    let pool = newSigilThreadPool(workers = 4)
    pool.start()

    var source = PoolSource.new()
    var counter = PoolCounter.new()
    let counterProxy = counter.moveToThread(pool)
    connectThreaded(source, valueChanged, counterProxy, setValue)

    for i in 1 .. 80:
      emit source.valueChanged(i)

    waitFor(proc(): bool {.gcsafe.} = seenCount.load() == 80)
    check seenCount.load() == 80
    check maxInSlot.load() == 1

    pool.stop()
    pool.join()

  test "stress test handles 10k actions":
    const
      ActorCount = 16
      ActionsPerActor = 625
      TotalActions = ActorCount * ActionsPerActor

    let pool = newSigilThreadPool(workers = 8)
    pool.start()

    var sources: seq[PoolSource]
    var proxies: seq[AgentProxy[PoolCounter]]
    for idx in 0 ..< ActorCount:
      var source = PoolSource.new()
      var counter = PoolCounter.new()
      let counterProxy = counter.moveToThread(pool)
      connectThreaded(source, valueChanged, counterProxy, setValueStress)
      sources.add(source)
      proxies.add(counterProxy)

    for action in 1 .. ActionsPerActor:
      for idx in 0 ..< ActorCount:
        emit sources[idx].valueChanged(action)

    waitFor(proc(): bool {.gcsafe.} =
      withLock stressLock:
        result = stressDone == TotalActions
    , attempts = 10_000)

    withLock stressLock:
      check stressDone == TotalActions
      check stressSum == ActorCount * (ActionsPerActor * (ActionsPerActor + 1) div 2)

    pool.stop()
    pool.join()

  test "multiple actors run on multiple workers":
    let pool = newSigilThreadPool(workers = 4)
    pool.start()

    var source1 = PoolSource.new()
    var source2 = PoolSource.new()
    var counter1 = PoolCounter.new()
    var counter2 = PoolCounter.new()
    let proxy1 = counter1.moveToThread(pool)
    let proxy2 = counter2.moveToThread(pool)

    connectThreaded(source1, valueChanged, proxy1, waitForRelease)
    connectThreaded(source2, valueChanged, proxy2, waitForRelease)

    emit source1.valueChanged(1)
    emit source2.valueChanged(2)

    # Hold both actors inside their slots so the test requires two workers,
    # without relying on how quickly the OS schedules a short batch of work.
    try:
      waitFor(proc(): bool {.gcsafe.} = countWorkers() == 2)
      check countWorkers() == 2
    finally:
      releaseWorkers.store(true)
    waitFor(proc(): bool {.gcsafe.} = doneCount.load() == 2)
    check doneCount.load() == 2

    pool.stop()
    pool.join()

  test "actor can move between workers over time":
    let pool = newSigilThreadPool(workers = 4)
    pool.start()

    var source = PoolSource.new()
    var counter = PoolCounter.new()
    let counterProxy = counter.moveToThread(pool)
    connectThreaded(source, valueChanged, counterProxy, setValue)

    for i in 1 .. 120:
      emit source.valueChanged(i)

    waitFor(proc(): bool {.gcsafe.} = seenCount.load() == 120)
    check seenCount.load() == 120
    check maxInSlot.load() == 1
    check countWorkers() >= 1

    pool.stop()
    pool.join()

  test "proxy round trip to local thread":
    let pool = newSigilThreadPool(workers = 2)
    pool.start()

    var source = PoolSource.new()
    var counter = PoolCounter.new()
    var local = PoolCounter.new()
    let counterProxy = counter.moveToThread(pool)

    connectThreaded(source, valueChanged, counterProxy, setValue)
    connectThreaded(counterProxy, pong, local, localDone(PoolCounter))

    emit source.valueChanged(42)
    waitFor(proc(): bool {.gcsafe.} =
      discard getCurrentSigilThread().pollAll()
      localValue.load() == 42
    )
    check localValue.load() == 42

    pool.stop()
    pool.join()

  test "registry keep alive add and delete":
    let pool = newSigilThreadPool(workers = 2)
    pool.start()

    var counter = PoolCounter.new()
    let counterProxy = counter.moveToThread(pool)
    registerGlobalName(sn"threadPoolCounter", counterProxy, override = true)
    let located = lookupGlobalName(sn"threadPoolCounter")
    check located.isSome
    check located.get().thread == pool.toSigilThread()
    check removeGlobalName(sn"threadPoolCounter", counterProxy)

    pool.stop()
    pool.join()

  test "deref while actor is busy closes after current call":
    let pool = newSigilThreadPool(workers = 2)
    pool.start()

    var source = PoolSource.new()
    var counter = PoolCounter.new()
    let counterProxy = counter.moveToThread(pool)
    connectThreaded(source, valueChanged, counterProxy, setValueSlow)
    emit source.valueChanged(1)
    waitFor(proc(): bool {.gcsafe.} = inSlot.load() == 1)
    counterProxy.remoteThread.send(ThreadSignal(kind: Deref,
        deref: counterProxy.remote.toKind(Agent)))

    waitFor(proc(): bool {.gcsafe.} = doneCount.load() == 1)
    check doneCount.load() == 1

    pool.stop()
    pool.join()
