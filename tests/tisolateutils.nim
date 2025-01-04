import std/isolation
import std/unittest
import std/os
import std/sequtils

import sigils
import sigils/isolateutils

import std/private/syslocks


type
  SomeAction* = ref object of Agent
    value: int
    lock: SysLock

  Counter* = ref object of Agent
    value: int


proc valueChanged*(tp: SomeAction, val: int) {.signal.}
proc updated*(tp: Counter, final: int) {.signal.}

proc setValue*(self: Counter, value: int) {.slot.} =
  echo "setValue! ", value, " id: ", self.getId, " (th:", getThreadId(), ")"
  if self.value != value:
    self.value = value
  echo "setValue:subcriptionsTable: ",
    self.subcriptionsTable.pairs().toSeq.mapIt(it[1].mapIt(it.tgt.getId))
  echo "setValue:listening: ", self.listening.toSeq.mapIt(it.getId)
  emit self.updated(self.value)

proc completed*(self: SomeAction, final: int) {.slot.} =
  echo "Action done! final: ", final, " id: ", self.getId(), " (th:", getThreadId(), ")"
  self.value = final

proc value*(self: Counter): int =
  self.value

suite "isolate utils":
  teardown:
    GC_fullCollect()


  test "isolateRuntime":
    type
      TestObj = object
      TestRef = ref object
      TestInner = object
        value: TestRef

    var
      a = SomeAction()
      isoA = isolateRuntime(a)
    check isoA.extract() == a

    var
      b = 33
      isoB = isolateRuntime(b)
    check isoB.extract() == b

    var
      c = TestObj()
      isoC = isolateRuntime(c)
    check isoC.extract() == c

    var
      d = "test"
      isoD = isolateRuntime(d)
    check isoD.extract() == d

    expect(IsolationError):
      echo "expect error..."
      var
        e = TestRef()
        e2 = e
        isoE = isolateRuntime(e)
      check isoE.extract() == e
    
    var
      f = TestInner()
    var isoF = isolateRuntime(f)
    check isoF.extract() == f
