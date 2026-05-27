import std/[os, sets, unittest]
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
var workerIds: Atomic[int]
var localValue: Atomic[int]

proc rememberWorker() =
  let bit = 1 shl (getThreadId() mod 30)
  workerIds.store(workerIds.load() or bit)

proc countBits(value: int): int =
  var bits = value
  while bits != 0:
    result.inc(bits and 1)
    bits = bits shr 1

proc setValue*(self: PoolCounter, value: int) {.slot.} =
  let now = inSlot.load() + 1
  inSlot.store(now)
  if now > maxInSlot.load():
    maxInSlot.store(now)
  rememberWorker()
  os.sleep(1)
  self.value = value
  seenCount.store(seenCount.load() + 1)
  inSlot.store(inSlot.load() - 1)
  emit self.pong(value)

proc setValueSlow*(self: PoolCounter, value: int) {.slot.} =
  inSlot.store(inSlot.load() + 1)
  rememberWorker()
  os.sleep(40)
  self.value = value
  doneCount.store(doneCount.load() + 1)
  inSlot.store(inSlot.load() - 1)

proc localDone*(self: PoolCounter, value: int) {.slot.} =
  localValue.store(value)

proc waitFor(target: proc(): bool {.gcsafe.}) =
  for _ in 1 .. 2_000:
    if target():
      return
    os.sleep(1)

suite "thread pool":
  setup:
    inSlot.store(0)
    maxInSlot.store(0)
    seenCount.store(0)
    doneCount.store(0)
    workerIds.store(0)
    localValue.store(0)
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

  test "multiple actors run on multiple workers":
    let pool = newSigilThreadPool(workers = 4)
    pool.start()

    var source1 = PoolSource.new()
    var source2 = PoolSource.new()
    var counter1 = PoolCounter.new()
    var counter2 = PoolCounter.new()
    let proxy1 = counter1.moveToThread(pool)
    let proxy2 = counter2.moveToThread(pool)

    connectThreaded(source1, valueChanged, proxy1, setValueSlow)
    connectThreaded(source2, valueChanged, proxy2, setValueSlow)

    emit source1.valueChanged(1)
    emit source2.valueChanged(2)

    waitFor(proc(): bool {.gcsafe.} = doneCount.load() == 2)
    check doneCount.load() == 2
    check countBits(workerIds.load()) >= 2

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
    check countBits(workerIds.load()) >= 1

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
