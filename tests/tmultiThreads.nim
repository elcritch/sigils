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
    obj: InnerA

  Counter* = ref object of Agent
    value: int
    obj: InnerC

  InnerA = object
    id: int

  InnerC = object
    id: int

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
      c = SomeAction.new()
    echo "thread runner!", " (th: ", getThreadId(), ")"
    echo "obj a: ", agentA.getSigilId
    echo "obj b: ", b.getSigilId
    echo "obj c: ", c.getSigilId
    startLocalThreadDefault()

    connect(agentA, valueChanged, b, setValue)
    connect(b, updated, c, SomeAction.completed())

    let bp: AgentProxy[Counter] = b.moveToThread(threadA)
    echo "obj bp: ", bp.getSigilId()

    registerGlobalName(sn"objectCounter", bp)

    let bid = cast[int](bp.remote.pt)
    emit agentA.valueChanged(bid)

    # Poll and check action response
    let ct = getCurrentSigilThread()
    ct.poll()
    check c.value == bid

    let res = lookupGlobalName(sn"objectCounter").get()
    check res.agent == bp.remote
    check res.thread == bp.remoteThread

    GC_fullCollect()

  test "test multiple thread setup":

    GC_fullCollect()

