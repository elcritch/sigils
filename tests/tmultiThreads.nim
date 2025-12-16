import std/isolation
import std/unittest
import std/os
import std/sequtils
import threading/atomics

import sigils
import sigils/threads
import sigils/registry

import std/terminal
import std/strutils


type
  SomeTrigger* = ref object of Agent

  Counter* = ref object of Agent
    value: int

  SomeTarget* = ref object of Agent
    value: int

proc valueChanged*(tp: SomeTrigger, val: int) {.signal.}
proc updated*(tp: Counter, final: int) {.signal.}

proc setValue*(self: Counter, value: int) {.slot.} =
  echo "set value: ", value
  if self.value != value:
    self.value = value
  if value == 756809:
    os.sleep(1)
  emit self.updated(self.value)

proc completed*(self: SomeTarget, final: int) {.slot.} =
  echo "Action done! final: ",
    final, " id: ", $self.unsafeWeakRef(), " (th: ", getThreadId(), ")"
  self.value = final

proc valuePrint*(tp: SomeTrigger, val: int) {.slot.} =
  echo "print tp: ", $tp.unsafeWeakRef(), " value: ", val, " (th: ", getThreadId(), ")"

var threadA = newSigilThread()
var threadB = newSigilThread()
var threadC = newSigilThread()

threadA.start()
threadB.start()
threadC.start()

var threadBRemoteReady: Atomic[int]
threadBRemoteReady.store 0

var actionA = SomeTrigger.new()
var actionCProx: AgentProxy[SomeTrigger]
var cpRef: AgentProxy[Counter]

suite "threaded agent slots":
  setup:
    printConnectionsSlotNames = {
      remoteSlot.pointer: "remoteSlot",
      localSlot.pointer: "localSlot",
      SomeTarget.completed().pointer: "completed",
      Counter.setValue().pointer: "setValue",
    }.toTable()

  test "create globalCounter and move to threadA":

    echo "sigil object thread connect change"
    var
      counter = Counter.new()
      target1 = SomeTarget.new()
      counter2 = Counter.new()
      target2 = SomeTarget.new()

    echo "counter global: ", counter.unsafeWeakRef()
    when defined(sigilsDebug):
      counter.debugName = "counter"
      target1.debugName = "target1"

    echo "thread runner!", " (th: ", getThreadId(), ")"
    echo "obj actionA: ", actionA.getSigilId
    echo "obj counter: ", counter.getSigilId
    echo "obj target1: ", target1.getSigilId
    startLocalThreadDefault()

    connect(actionA, valueChanged, counter, setValue)
    connect(counter, updated, target1, SomeTarget.completed())
    connect(counter2, updated, target2, SomeTarget.completed())

    let counterProxy: AgentProxy[Counter] = counter.moveToThread(threadA)
    #cpRef = counterProxy
    echo "obj bp: ", counterProxy.getSigilId()
    when defined(sigilsDebug):
      counterProxy.debugName = "counterProxyLocal"

    registerGlobalName(sn"globalCounter", counterProxy)
    registerGlobalAgent(sn"globalCounter2", threadA, counter2)

    let bid = cast[int](counterProxy.remote.pt)
    emit actionA.valueChanged(bid)

    # Poll and check action response
    let ct = getCurrentSigilThread()
    ct.poll()
    check target1.value == bid

    let res = lookupGlobalName(sn"globalCounter").get()
    check res.agent == counterProxy.remote
    check res.thread == counterProxy.remoteThread

    let res2 = lookupGlobalName(sn"globalCounter2").get()
    check res2.agent == counterProxy.remote
    check res2.thread == counterProxy.remoteThread


  test "connect target2 on threadB to globalCounter":
    proc remoteTrigger(counter: AgentProxy[SomeTarget]) {.signal.}

    proc remoteCompleted(self: SomeTarget, final: int) {.slot.} =
      echo "Action done on remote! final: ",
        final, " id: ", $self.unsafeWeakRef(), " (th: ", getThreadId(), ")"
      self.value = final
      threadBRemoteReady.store 3

    proc remoteRun(cc2: SomeTarget) {.slot.} =
      os.sleep(10)
      echo "REMOTE RUN!"
      let localCounterProxy = lookupAgentProxy(sn"globalCounter", Counter)
      if localCounterProxy != nil:
        connectThreaded(localCounterProxy, updated, cc2, remoteCompleted(SomeTarget))
        threadBRemoteReady.store 1
      else:
        threadBRemoteReady.store 2

    var c2 = SomeTarget.new()
    let c2p: AgentProxy[SomeTarget] = c2.moveToThread(threadB)
    echo "obj c2p: ", c2p.getSigilId()

    connectThreaded(c2p, remoteTrigger, c2p, remoteRun)

    emit c2p.remoteTrigger()

    for i in 1..100_000_000:
      if threadBRemoteReady.load() != 0: break
      doAssert i != 100_000_000

    check threadBRemoteReady.load() == 1
    threadBRemoteReady.store 0

    GC_fullCollect()

  test "connect actionB on threadC to globalCounter":
    proc remoteTrigger(counter: AgentProxy[SomeTrigger]) {.signal.}

    proc remoteSetup(self: SomeTrigger) {.slot.} =
      os.sleep(10)
      echo "REMOTE RUN!"
      let localCounterProxy = lookupAgentProxy(sn"globalCounter", Counter)
      if localCounterProxy != nil:
        echo "connecting: ", self.unsafeWeakRef(), " to: ", localCounterProxy.remote, " th: ", " (th: ", getThreadId(), ")"
        connectThreaded(self, valueChanged, localCounterProxy, setValue(Counter))
        #connect(self, valueChanged, self, valuePrint(SomeTrigger))
        threadBRemoteReady.store 1
      else:
        threadBRemoteReady.store 2

    var actionC = SomeTrigger.new()
    #connect(actionC, valueChanged, actionC, valuePrint(SomeTrigger))
    actionCProx = actionC.moveToThread(threadC)
    echo "obj actionBProx: ", actionCProx.getSigilId()

    connectThreaded(actionCProx, remoteTrigger, actionCProx, remoteSetup)

    threadBRemoteReady.store 0
    emit actionCProx.remoteTrigger()

    for i in 1..100_000_000:
      if threadBRemoteReady.load() == 1: break

    check threadBRemoteReady.load() == 1

    GC_fullCollect()

  test "ensure globalCounter update updates target2":
    echo "main thread: ", " (th: ", getThreadId(), ")"
    proc valueChanged(st: AgentProxy[SomeTrigger], val: int) {.signal.}

    proc setValue(c2: SomeTrigger, val: int) {.slot.} =
      emit c2.valueChanged(val)

    threadBRemoteReady.store 0
    connect(actionCProx, valueChanged, actionCProx, setValue(SomeTrigger))
    printConnections(actionCProx)
    emit actionCProx.valueChanged(1010)

    for i in 1..1_000:
      os.sleep(1)
      if threadBRemoteReady.load() == 3: break

    check threadBRemoteReady.load() == 3

