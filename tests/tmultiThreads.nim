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
  if self.value != value:
    self.value = value
  if value == 756809:
    os.sleep(1)
  emit self.updated(self.value)

proc completed*(self: SomeTarget, final: int) {.slot.} =
  echo "Action done! final: ",
    final, " id: ", $self.unsafeWeakRef(), " (th: ", getThreadId(), ")"
  self.value = final


var threadA = newSigilThread()
var threadB = newSigilThread()

threadA.start()
threadB.start()

var threadBRemoteReady: Atomic[int]
threadBRemoteReady.store 0

var actionA = SomeTrigger.new()

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

    echo "thread runner!", " (th: ", getThreadId(), ")"
    echo "obj actionA: ", actionA.getSigilId
    echo "obj counter: ", counter.getSigilId
    echo "obj target1: ", target1.getSigilId
    startLocalThreadDefault()

    connect(actionA, valueChanged, counter, setValue)
    connect(counter, updated, target1, SomeTarget.completed())

    let counterProxy: AgentProxy[Counter] = counter.moveToThread(threadA)
    echo "obj bp: ", counterProxy.getSigilId()

    registerGlobalName(sn"globalCounter", counterProxy)

    let bid = cast[int](counterProxy.remote.pt)
    emit actionA.valueChanged(bid)

    # Poll and check action response
    let ct = getCurrentSigilThread()
    ct.poll()
    check target1.value == bid

    let res = lookupGlobalName(sn"globalCounter").get()
    check res.agent == counterProxy.remote
    check res.thread == counterProxy.remoteThread

  test "connect target2 on threadB to globalCounter":
    proc remoteTrigger(counter: AgentProxy[SomeTarget]) {.signal.}

    proc remoteCompleted(self: SomeTarget, final: int) {.slot.} =
      echo "Action done on remote! final: ",
        final, " id: ", $self.unsafeWeakRef(), " (th: ", getThreadId(), ")"
      self.value = final
      threadBRemoteReady.store 3

    proc remoteRun(cc2: SomeTarget) {.slot.} =
      echo "remote run!"
      let res = lookupGlobalName(sn"globalCounter")
      check res.isSome()
      let loc = res.get()
      echo "global counter found: ", loc

      let localCounterProxy = loc.toAgentProxy(Counter)
      if localCounterProxy != nil:
        connectThreaded(localCounterProxy, updated, cc2, cc2.type.completed())
        threadBRemoteReady.store 1
      else: 
        threadBRemoteReady.store 2

    var c2 = SomeTarget.new()
    let c2p: AgentProxy[SomeTarget] = c2.moveToThread(threadB)
    echo "obj c2p: ", c2p.getSigilId()

    connectThreaded(c2p, remoteTrigger, c2p, remoteRun)

    emit c2p.remoteTrigger()

    for i in 1..1_000_000:
      if threadBRemoteReady.load() != 0: break
      doAssert i != 1_000_000

    check threadBRemoteReady.load() == 1
    threadBRemoteReady.store 0
    
    GC_fullCollect()

  test "ensure globalCounter update updates target2":

    emit actionA.valueChanged(1010)
    
    for i in 1..1_000_000:
      if threadBRemoteReady.load() != 0: break
      doAssert i != 1_000_000

    check threadBRemoteReady.load() == 3

    
