{.define: thetosTrackAllocs.}

import std/unittest
import sigils/selectors
import thetos/private/core

when defined(posix):
  import std/posix

type CacheReceiver = ref object of DynamicAgent

protocol CacheProtocol from CacheReceiver:
  method cachedValue(self: CacheReceiver): int = 1

protocol ExtraProtocol:
  method extraValue(): int

protocol ExtraImplementation of ExtraProtocol:
  method extraValue(self: CacheReceiver): int = 2

proc checkProtocols() =
  let receiver = CacheReceiver().withProto().withProtocol(ExtraImplementation)
  doAssert receiver.cachedValue == 1
  doAssert receiver.extraValue == 2

proc nimWorker() {.thread.} =
  {.cast(gcsafe).}:
    # The receiver is confined to this worker and has no user callbacks.
    checkProtocols()

proc runNimWorkers() =
  var workers: array[8, Thread[void]]
  for worker in workers.mitems:
    createThread(worker, nimWorker)
  for worker in workers.mitems:
    joinThread(worker)

when defined(posix):
  proc foreignWorker(_: pointer): pointer {.noconv.} =
    setupForeignThreadGc()
    try:
      checkProtocols()
    finally:
      tearDownForeignThreadGc()

  proc runForeignWorkers() =
    for _ in 0..<8:
      var worker: Pthread
      doAssert pthread_create(addr worker, nil, foreignWorker, nil) == 0
      doAssert pthread_join(worker, nil) == 0

suite "generated protocol caches across threads":
  test "repeated Nim workers reuse protocol maps":
    let liveBeforeWarmup = liveAllocations()
    runNimWorkers()
    let liveAfterWarmup = liveAllocations()
    check liveAfterWarmup > liveBeforeWarmup
    runNimWorkers()
    check liveAllocations() == liveAfterWarmup

  when defined(posix):
    test "foreign threads can exit without leaking protocol maps":
      runForeignWorkers()
      let liveAfterWarmup = liveAllocations()
      runForeignWorkers()
      check liveAllocations() == liveAfterWarmup
