import sigils, sigils/threads

type
  Trigger = ref object of AgentActor

  Worker = ref object of AgentActor
    value: int

  Collector = ref object of AgentActor
    a: int
    b: int

proc valueChanged(tp: Trigger, val: int) {.signal.}
proc updated(tp: Worker, final: int) {.signal.}

proc setValue(self: Worker, value: int) {.slot.} =
  self.value = value
  echo "worker:setValue: ", value, " (th: ", getThreadId(), ")"
  emit self.updated(self.value)

proc gotA(self: Collector, final: int) {.slot.} =
  echo "collector: gotA: ", final, " (th: ", getThreadId(), ")"
  self.a = final

proc gotB(self: Collector, final: int) {.slot.} =
  echo "collector: gotB: ", final, " (th: ", getThreadId(), ")"
  self.b = final

let trigger = Trigger()
let collector = Collector()

let threadA = newSigilThread()
let threadB = newSigilThread()
threadA.start()
threadB.start()
startLocalThreadDefault()

var wA = Worker()
var wB = Worker()

let workerA: AgentProxy[Worker] = wA.moveToThread(threadA)
let workerB: AgentProxy[Worker] = wB.moveToThread(threadB)

connectThreaded(trigger, valueChanged, workerA, setValue)
connectThreaded(trigger, valueChanged, workerB, setValue)
connectThreaded(workerA, updated, collector, Collector.gotA())
connectThreaded(workerB, updated, collector, Collector.gotB())

let ct = getCurrentSigilThread()

for n in [42, 137]:
  echo "N: ", n
  emit trigger.valueChanged(n)
  discard ct.poll() # workerA result
  discard ct.poll() # workerB result
  echo "collector: ", collector.a, " ", collector.b, " n: ", n
  doAssert collector.a == n
  doAssert collector.b == n

setRunning(threadA, false)
setRunning(threadB, false)
threadA.join()
threadB.join()
