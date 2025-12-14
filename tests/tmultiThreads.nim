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
      b = Counter.new()
      c1 = SomeAction.new()
    echo "thread runner!", " (th: ", getThreadId(), ")"
    echo "obj a: ", agentA.getSigilId
    echo "obj b: ", b.getSigilId
    echo "obj c: ", c1.getSigilId
    startLocalThreadDefault()

    connect(agentA, valueChanged, b, setValue)
    connect(b, updated, c1, SomeAction.completed())

    let bp: AgentProxy[Counter] = b.moveToThread(threadA)
    echo "obj bp: ", bp.getSigilId()

    registerGlobalName(sn"objectCounter", bp)

    let bid = cast[int](bp.remote.pt)
    emit agentA.valueChanged(bid)

    # Poll and check action response
    let ct = getCurrentSigilThread()
    ct.poll()
    check c1.value == bid

    let res = lookupGlobalName(sn"objectCounter").get()
    check res.agent == bp.remote
    check res.thread == bp.remoteThread

    proc remoteTrigger(counter: AgentProxy[SomeAction]) {.signal.}

    proc remoteRun(cc: SomeAction) {.slot.} =
      echo "remote run!"
      let res = lookupGlobalName(sn"objectCounter")
      check res.isSome()
      let loc = res.get()
      echo "counter found: ", loc

      let counter = loc.toAgentProxy(Counter)


    var c2 = SomeAction.new()
    let c2p: AgentProxy[SomeAction] = c2.moveToThread(threadB)
    echo "obj c2p: ", c2p.getSigilId()

    connectThreaded(c2p, remoteTrigger, c2p, remoteRun)

    emit c2p.remoteTrigger()
    os.sleep(200)
    
    GC_fullCollect()

