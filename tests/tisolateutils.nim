import std/isolation
import std/unittest
import std/os
import std/sequtils

import sigils
import sigils/isolateutils
import sigils/weakrefs

import std/private/syslocks

import threading/smartptrs
import threading/channels

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
      a = SomeAction(value: 10)
    
    echo "A: ", a.unsafeGcCount()
    var
      isoA = isolateRuntime(move a)
    check a.isNil
    check isoA.extract().value == 10

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

type
  NonCopy = object

  Foo = object of RootObj
    id: int
    thr: Thread[int]
    ch: Chan[int]

  BarImpl = object of Foo

proc `=copy`*(a: var NonCopy; b: NonCopy) {.error.}

proc newBarImpl*(): SharedPtr[BarImpl] =
  var thr = BarImpl(id: 1234)
  result = newSharedPtr(isolateRuntime(thr))

var localFoo {.threadVar.}: SharedPtr[Foo]

proc toFoo*[R: Foo](t: SharedPtr[R]): SharedPtr[Foo] =
  cast[SharedPtr[Foo]](t)

proc startLocalFoo*() =
  echo "startLocalFoo"
  if localFoo.isNil:
    var st = newBarImpl()
    localFoo = st.toFoo()
  echo "startLocalThread: ", localFoo.repr

proc getCurrentFoo*(): SharedPtr[Foo] =
  echo "getCurrentFoo"
  startLocalFoo()
  assert not localFoo.isNil
  return localFoo

suite "isolate utils":
  test "isolateRuntime sharedPointer":
    echo "test"

    let test = getCurrentFoo()
    echo "test: ", test
    check not test.isNil
    check test[].id == 1234
