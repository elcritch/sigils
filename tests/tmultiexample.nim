import sigils
import sigils/threads

type
  Trigger = ref object of Agent

  Worker = ref object of Agent
    value: int

  Collector = ref object of Agent
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

emit trigger.valueChanged(42)

let ct = getCurrentSigilThread()
discard ct.poll() # workerA result
discard ct.poll() # workerB result
doAssert collector.a == 42
doAssert collector.b == 42

setRunning(threadA, false)
setRunning(threadB, false)
threadA.join()
threadB.join()
