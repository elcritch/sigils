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
  SomeAction* = ref object of Agent
    value: int

  Counter* = ref object of Agent
    value: int

proc valueChanged*(tp: SomeAction, val: int) {.signal.}
proc updated*(tp: Counter, final: int) {.signal.}

proc setValue*(self: Counter, value: int) {.slot.} =
  if self.value != value:
    self.value = value
  if value == 756809:
    os.sleep(1)
  emit self.updated(self.value)

proc completed*(self: SomeAction, final: int) {.slot.} =
  echo "Action done! final: ",
    final, " id: ", $self.unsafeWeakRef(), " (th: ", getThreadId(), ")"
  self.value = final


var threadA = newSigilThread()
var threadB = newSigilThread()

threadA.start()
threadB.start()

var threadBRemoteReady: Atomic[int]
threadBRemoteReady.store 0

var agentA = SomeAction.new()

suite "threaded agent slots":
  setup:
    printConnectionsSlotNames = {
      remoteSlot.pointer: "remoteSlot",
      localSlot.pointer: "localSlot",
      SomeAction.completed().pointer: "completed",
      Counter.setValue().pointer: "setValue",
    }.toTable()

  test "connect, moveToThread, and register":
    var agentA = SomeAction.new()

    echo "sigil object thread connect change"
    var
      counter = Counter.new()
      c1 = SomeAction.new()
    echo "thread runner!", " (th: ", getThreadId(), ")"
    echo "obj a: ", agentA.getSigilId
    echo "obj counter: ", counter.getSigilId
    echo "obj c: ", c1.getSigilId
    startLocalThreadDefault()

    connect(agentA, valueChanged, counter, setValue)
    connect(counter, updated, c1, SomeAction.completed())

    let counterProxy: AgentProxy[Counter] = counter.moveToThread(threadA)
    echo "obj bp: ", counterProxy.getSigilId()

    registerGlobalName(sn"objectCounter", counterProxy)

    let bid = cast[int](counterProxy.remote.pt)
    emit agentA.valueChanged(bid)

    # Poll and check action response
    let ct = getCurrentSigilThread()
    ct.poll()
    check c1.value == bid

    let res = lookupGlobalName(sn"objectCounter").get()
    check res.agent == counterProxy.remote
    check res.thread == counterProxy.remoteThread

    proc remoteTrigger(counter: AgentProxy[SomeAction]) {.signal.}

    proc remoteRun(cc2: SomeAction) {.slot.} =
      echo "remote run!"
      let res = lookupGlobalName(sn"objectCounter")
      check res.isSome()
      let loc = res.get()
      echo "counter found: ", loc

      let localCounterProxy = loc.toAgentProxy(Counter)
      if localCounterProxy != nil:
        connectThreaded(cc2, valueChanged, localCounterProxy, setValue)

      threadBRemoteReady.store 1


    var c2 = SomeAction.new()
    let c2p: AgentProxy[SomeAction] = c2.moveToThread(threadB)
    echo "obj c2p: ", c2p.getSigilId()

    connectThreaded(c2p, remoteTrigger, c2p, remoteRun)

    emit c2p.remoteTrigger()

    for i in 1..100_000:
      if threadBRemoteReady.load() == 1: break
      doAssert i != 100_000

    check threadBRemoteReady.load() == 1
    
    GC_fullCollect()

