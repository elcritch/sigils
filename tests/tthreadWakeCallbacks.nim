import std/assertions

import threading/atomics

import sigils

type ProducerRequest = object
  destination: SigilThreadPtr

proc enqueueFromWorker(request: ProducerRequest) {.thread.} =
  request.destination.send(ThreadSignal(kind: Trigger))

proc newCountingWakeCallback(
    count: ptr Atomic[int],
): SigilThreadWakeCallback =
  result = proc() {.gcsafe, raises: [].} =
    discard count[].fetchAdd(1)

block multiple_and_late_wake_callbacks:
  let destination = newSigilThread()
  let firstCount = cast[ptr Atomic[int]](allocShared0(sizeof(Atomic[int])))
  let secondCount = cast[ptr Atomic[int]](allocShared0(sizeof(Atomic[int])))
  firstCount[].store(0)
  secondCount[].store(0)

  destination.send(ThreadSignal(kind: Trigger))
  destination.toSigilThread().addWakeCallback(
    newCountingWakeCallback(firstCount),
  )
  destination.toSigilThread().addWakeCallback(
    newCountingWakeCallback(secondCount),
  )

  doAssert firstCount[].load() == 1,
    "late registration should immediately notify the first callback"
  doAssert secondCount[].load() == 1,
    "late registration should immediately notify the second callback"

  var producer: Thread[ProducerRequest]
  createThread(
    producer,
    enqueueFromWorker,
    ProducerRequest(destination: destination.toSigilThread()),
  )
  producer.joinThread()

  doAssert firstCount[].load() == 2,
    "a worker enqueue should notify the first callback"
  doAssert secondCount[].load() == 2,
    "a worker enqueue should notify the second callback"
  doAssert destination.pollAll() == 2,
    "both messages should remain in the destination queue until drained"

  destination.toSigilThread().clearWakeCallbacks()
  deallocShared(firstCount)
  deallocShared(secondCount)
