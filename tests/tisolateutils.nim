import std/isolation
import std/unittest
import std/os
import std/sequtils

import sigils
import sigils/isolateutils

type
  SomeAction* = ref object of Agent
    value: int

  Counter* = ref object of Agent
    value: int

proc valueChanged*(tp: SomeAction, val: int) {.signal.}
proc updated*(tp: Counter, final: int) {.signal.}

proc setValue*(self: Counter, value: int) {.slot.} =
  echo "setValue! ", value, " id: ", self.getId, " (th:", getThreadId(), ")"
  if self.value != value:
    self.value = value
  echo "setValue:subscribers: ",
    self.subscribers.pairs().toSeq.mapIt(it[1].mapIt(it.tgt.getId))
  echo "setValue:subscribedTo: ", self.subscribedTo.toSeq.mapIt(it.getId)
  emit self.updated(self.value)

proc completed*(self: SomeAction, final: int) {.slot.} =
  echo "Action done! final: ", final, " id: ", self.getId(), " (th:", getThreadId(), ")"
  self.value = final

proc value*(self: Counter): int =
  self.value

suite "isolate utils":
  teardown:
    GC_fullCollect()


  test "tryIsolate":
    type
      TestObj = object
      TestRef = ref object

    var
      a = SomeAction()
      b = 33
      c = TestObj()
      d = "test"
      e = TestRef()

    # echo "thread runner!"
    let isoA = tryIsolate(a)
    let isoB = tryIsolate(b)
    let isoC = tryIsolate(c)
    let isoD = tryIsolate(d)

    expect(IsolateError):
      var e2 = e
      let isoE = tryIsolate(e)
