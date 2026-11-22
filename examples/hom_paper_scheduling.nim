## Scheduling and future examples adapted from Higher Order Messaging, §§4.2–4.3.
## https://scg.unibe.ch/archive/papers/Weih05aHigherOrderMessagingOOPSLA2005.pdf
import std/[algorithm, asyncdispatch, monotimes, os, times]
import sigils

type
  Job = ref object of DynamicAgent
    ran: bool

  Batch = array[3, int]

  Sorter = ref object of AgentActor

  Caller = ref object of AgentActor
    sorted: Future[Batch]
    workerId: int

protocol JobMessages from Job:
  method doSomething(self: Job) =
    self.ran = true

proc sendAfter[A](
    receiver: DynamicAgent, message: Selector[A, tuple[]], args: A, delayMs: int
): Future[bool] {.async.} =
  await sleepAsync(delayMs)
  return receiver.sendLocalIfHandled(message, args)

proc sortRequested(caller: Caller, batch: Batch) {.signal.}
proc sortFinished(sorter: Sorter, batch: Batch, workerId: int) {.signal.}

proc sortBatch(sorter: Sorter, batch: Batch) {.slot.} =
  var sorted = batch
  sorted.sort()
  emit sorter.sortFinished(sorted, getThreadId())

proc receiveSorted(caller: Caller, batch: Batch, workerId: int) {.slot.} =
  caller.workerId = workerId
  caller.sorted.complete(batch)

proc deferredSend() =
  let
    job = Job().withProto()
    delivered = job.sendAfter(doSomething(), (), delayMs = 1)
  doAssert not job.ran
  doAssert waitFor(delivered)
  doAssert job.ran

proc mergeWithWorker() =
  startLocalThreadDefault()
  let worker = newSigilThreadPool(workers = 1)
  worker.start()
  defer:
    worker.stop()
    worker.join()

  let caller = Caller(sorted: newFuture[Batch]("sorted batch"))
  var sorter = Sorter()
  let proxy = sorter.moveToThread(worker)
  connectThreaded(caller, sortRequested, proxy, sortBatch)
  connectThreaded(proxy, sortFinished, caller, Caller.receiveSorted())

  # Dispatch one sort to the worker and sort the other half on this thread.
  emit caller.sortRequested([5, 1, 3])
  var right = [4, 6, 2]
  right.sort()

  let
    currentThread = getCurrentSigilThread()
    deadline = getMonoTime() + initDuration(seconds = 5)
  while not caller.sorted.finished and getMonoTime() < deadline:
    currentThread.pollAll()
    if not caller.sorted.finished:
      sleep(1)
  doAssert caller.sorted.finished, "timed out waiting for the worker reply"
  doAssert caller.workerId != getThreadId()

  var merged: seq[int]
  merge(merged, caller.sorted.read(), right)
  doAssert merged == @[1, 2, 3, 4, 5, 6]

when isMainModule:
  deferredSend()
  mergeWithWorker()
