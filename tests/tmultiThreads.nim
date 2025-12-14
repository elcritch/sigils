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

var globalLastInnerADestroyed: Atomic[int]
globalLastInnerADestroyed.store(0)
proc `=destroy`*(obj: InnerA) =
  if obj.id != 0:
    echo "destroyed InnerA!"
  globalLastInnerADestroyed.store obj.id

var globalLastInnerCDestroyed: Atomic[int]
globalLastInnerCDestroyed.store(0)

proc `=destroy`*(obj: InnerC) =
  if obj.id != 0:
    echo "destroyed InnerC!"
  globalLastInnerCDestroyed.store obj.id

proc valueChanged*(tp: SomeAction, val: int) {.signal.}
proc updated*(tp: Counter, final: int) {.signal.}

proc setValue*(self: Counter, value: int) {.slot.} =
  if self.value != value:
    self.value = value
  if value == 756809:
    os.sleep(1)
  emit self.updated(self.value)

var globalCounter: Atomic[int]
globalCounter.store(0)

proc setValueGlobal*(self: Counter, value: int) {.slot.} =
  echo "setValueGlobal! ",
    value, " id: ", self.getSigilId().int, " (th: ", getThreadId(), ")"
  if self.value != value:
    self.value = value
  globalCounter.store(value)

var globalLastTicker: Atomic[int]
proc ticker*(self: Counter) {.slot.} =
  for i in 3 .. 3:
    echo "tick! i:", i, " ", self.unsafeWeakRef(), " (th: ", getThreadId(), ")"
    globalLastTicker.store i
    printConnections(self)
    emit self.updated(i)

proc completed*(self: SomeAction, final: int) {.slot.} =
  echo "Action done! final: ",
    final, " id: ", $self.unsafeWeakRef(), " (th: ", getThreadId(), ")"
  self.value = final

proc completedSum*(self: SomeAction, final: int) {.slot.} =
  when defined(debug):
    echo "Action done! final: ",
      final, " id: ", $self.unsafeWeakRef(), " (th: ", getThreadId(), ")"
  self.value = self.value + final

proc value*(self: Counter): int =
  self.value

suite "threaded agent slots":
  setup:
    printConnectionsSlotNames = {
      remoteSlot.pointer: "remoteSlot",
      localSlot.pointer: "localSlot",
      SomeAction.completed().pointer: "completed",
      Counter.ticker().pointer: "ticker",
      Counter.setValue().pointer: "setValue",
      Counter.setValueGlobal().pointer: "setValueGlobal",
    }.toTable()

  test "connect, moveToThread, and register":
    var a = SomeAction.new()

    block:
      echo "sigil object thread connect change"
      var
        b = Counter.new()
        c = SomeAction.new()
      echo "thread runner!", " (th: ", getThreadId(), ")"
      echo "obj a: ", a.getSigilId
      echo "obj b: ", b.getSigilId
      echo "obj c: ", c.getSigilId
      let thread = newSigilThread()
      thread.start()
      startLocalThreadDefault()

      connect(a, valueChanged, b, setValue)
      connect(b, updated, c, SomeAction.completed())

      let bp: AgentProxy[Counter] = b.moveToThread(thread)
      echo "obj bp: ", bp.getSigilId()

      registerGlobalName(sn"objectCounter", bp)

      let bid = cast[int](bp.remote.pt)
      emit a.valueChanged(bid)
      let ct = getCurrentSigilThread()
      ct.poll()
      check c.value == bid

      let res = lookupGlobalName(sn"objectCounter")
      check res.agent == bp.remote
      check res.thread == bp.remoteThread


    GC_fullCollect()

