import std/[os, random]

import sigils
import sigils/threadDefault
import sigils/threadPool
import sigils/threadProxies

type
  Dispatcher = ref object of AgentActor

  Worker = ref object of AgentActor
    name: string
    processed: int

  Collector = ref object of AgentActor
    received: int
    total: int

proc workRequested*(dispatcher: Dispatcher, value: int) {.signal.}
proc workFinished*(worker: Worker, workerName: string, value: int,
    runningTotal: int, threadId: int) {.signal.}

proc doWork*(worker: Worker, value: int) {.slot.} =
  os.sleep(1000 + rand(950))
  worker.processed += value
  echo worker.name, " processed ", value, " on thread ", getThreadId()
  emit worker.workFinished(worker.name, value, worker.processed, getThreadId())

proc collectResult*(
    collector: Collector,
    workerName: string,
    value: int,
    runningTotal: int,
    threadId: int,
) {.slot.} =
  inc collector.received
  collector.total += value
  echo "collector received ", value,
    " from ", workerName,
    " runningTotal=", runningTotal,
    " workerThread=", threadId,
    " localThread=", getThreadId()

proc waitForResults(
    collector: Collector,
    expected: int,
    timeoutMs = 15_000,
    pollIntervalMs = 25,
) =
  let localThread = getCurrentSigilThread()
  for _ in 1..(timeoutMs div pollIntervalMs):
    discard localThread.pollAll()
    if collector.received == expected:
      return
    os.sleep(pollIntervalMs)
  raise newException(CatchableError, "timed out waiting for thread pool results")

randomize()
startLocalThreadDefault()

let pool = newSigilThreadPool(workers = 4)
pool.start()

let
  dispatcher = Dispatcher()
  collector = Collector()

var
  imageWorker = Worker(name: "image-worker")
  indexWorker = Worker(name: "index-worker")

let
  imageProxy = imageWorker.moveToThread(pool)
  indexProxy = indexWorker.moveToThread(pool)

connectThreaded(dispatcher, workRequested, imageProxy, doWork)
connectThreaded(dispatcher, workRequested, indexProxy, doWork)
connectThreaded(imageProxy, workFinished, collector, Collector.collectResult())
connectThreaded(indexProxy, workFinished, collector, Collector.collectResult())

for value in [10, 20, 30, 40]:
  echo "dispatching ", value
  emit dispatcher.workRequested(value)
  os.sleep(850)

waitForResults(collector, expected = 6)

doAssert collector.received == 6
doAssert collector.total == 120

pool.stop()
pool.join()
