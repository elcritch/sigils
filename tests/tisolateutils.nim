import std/isolation
import std/unittest
import std/os
import std/sequtils
import std/tables

import sigils
import sigils/isolateutils
import sigils/weakrefs

import std/private/syslocks

import threading/smartptrs
import threading/channels

type
  IsolationLeaf = ref object
    value: int

  IsolationBox[T] = object
    value: T

  IsolationTree = object
    value: int
    children: seq[IsolationTree]

  IsolationCycle = ref object
    children: seq[IsolationCycle]

  IsolationChoice = object
    case hasRef: bool
    of true:
      leaf: IsolationLeaf
    of false:
      value: int

  IsolationRecursive[T] = object
    children: seq[IsolationRecursive[T]]
    value: T

  IsolationBase[T] = object of RootObj
    value: T

  IsolationInherited[T] = object of IsolationBase[T]
    extra: int

  IsolationSequence[T] = seq[T]

  SomeAction* = ref object of Agent
    value: int

  Counter* = ref object of Agent
    value: int

proc valueChanged*(tp: SomeAction, val: int) {.signal.}
proc updated*(tp: Counter, final: int) {.signal.}

proc setValue*(self: Counter, value: int) {.slot.} =
  echo "setValue! ", value, " id: ", self.getSigilId, " (th:", getThreadId(), ")"
  if self.value != value:
    self.value = value
  echo "setValue:listening: ", self.listening.toSeq.mapIt(it.getSigilId)
  emit self.updated(self.value)

proc completed*(self: SomeAction, final: int) {.slot.} =
  echo "Action done! final: ",
    final, " id: ", self.getSigilId(), " (th:", getThreadId(), ")"
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

    var a = SomeAction(value: 10)

    echo "A: ", a.unsafeGcCount()
    var isoA = isolateRuntime(move a)
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

    var f = TestInner()
    var isoF = isolateRuntime(f)
    check isoF.extract() == f

  test "runtime checks reject sequence and array elements with outside owners":
    let outside = IsolationLeaf(value: 42)
    var sequence = @[outside]
    expect(IsolationError):
      var isolated = isolateRuntime(move sequence)
      discard isolated.extract()
    var array = [outside]
    expect(IsolationError):
      var isolated = isolateRuntime(move array)
      discard isolated.extract()
    check outside.value == 42

  test "runtime checks follow nested generic objects tuples and containers":
    let outside = IsolationLeaf(value: 43)
    var nested = @[IsolationBox[tuple[leaves: array[1, seq[IsolationLeaf]]]](
      value: (leaves: [@[outside]])
    )]
    expect(IsolationError):
      var isolated = isolateRuntime(move nested)
      discard isolated.extract()
    check outside.value == 43

  test "runtime checks follow containers stored in refs":
    type Owner = ref object
      leaves: seq[IsolationBox[IsolationLeaf]]
    let outside = IsolationLeaf(value: 44)
    var owner = Owner(leaves: @[IsolationBox[IsolationLeaf](value: outside)])
    expect(IsolationError):
      var isolated = isolateRuntime(move owner)
      discard isolated.extract()
    check outside.value == 44

  test "positional tuples and inherited generic fields retain ref checks":
    let outside = IsolationLeaf(value: 53)
    var positional = @[(1, outside)]
    expect(IsolationError):
      var isolated = isolateRuntime(move positional)
      discard isolated.extract()
    var inherited = @[IsolationInherited[IsolationLeaf](value: outside)]
    expect(IsolationError):
      var isolated = isolateRuntime(move inherited)
      discard isolated.extract()
    check outside.value == 53

  test "recursive generic values check refs after recursive fields":
    let outside = IsolationLeaf(value: 54)
    var shared = @[IsolationRecursive[IsolationLeaf](value: outside)]
    expect(IsolationError):
      var isolated = isolateRuntime(move shared)
      discard isolated.extract()
    var owned = @[IsolationRecursive[IsolationLeaf](
      children: @[IsolationRecursive[IsolationLeaf](value: IsolationLeaf(
          value: 55))],
      value: IsolationLeaf(value: 56)
    )]
    var isolated = isolateRuntime(move owned)
    let recovered = isolated.extract()
    check recovered[0].children[0].value.value == 55
    check recovered[0].value.value == 56

  test "sequence aliases and standard table elements follow their value types":
    let outside = IsolationLeaf(value: 57)
    var aliases: IsolationSequence[IsolationSequence[IsolationLeaf]] = @[@[outside]]
    expect(IsolationError):
      var isolated = isolateRuntime(move aliases)
      discard isolated.extract()
    var table = {"leaf": outside}.toTable()
    var tables = @[move table]
    expect(IsolationError):
      var isolated = isolateRuntime(move tables)
      discard isolated.extract()
    check outside.value == 57

  test "uniquely owned nested containers isolate without extra ref counts":
    var nested = @[IsolationBox[tuple[leaves: array[1, seq[IsolationLeaf]]]](
      value: (leaves: [@[IsolationLeaf(value: 45)]])
    )]
    var isolated = isolateRuntime(move nested)
    let recovered = isolated.extract()
    check recovered[0].value.leaves[0][0].value == 45
    check recovered[0].value.leaves[0][0].unsafeGcCount() == 1

  test "empty and ref-free containers including recursive value types isolate":
    var empty: seq[IsolationLeaf]
    var isolatedEmpty = isolateRuntime(move empty)
    check isolatedEmpty.extract().len == 0
    var values = @[IsolationTree(value: 46, children: @[IsolationTree(value: 47)])]
    var isolatedValues = isolateRuntime(move values)
    let recovered = isolatedValues.extract()
    check recovered[0].value == 46
    check recovered[0].children[0].value == 47
    var strings = ["one", "two"]
    var isolatedStrings = isolateRuntime(move strings)
    check isolatedStrings.extract() == ["one", "two"]

  test "ref-bearing variant containers inspect only the active fields":
    var plain = @[IsolationChoice(hasRef: false, value: 48)]
    var isolatedPlain = isolateRuntime(move plain)
    check isolatedPlain.extract()[0].value == 48
    let outside = IsolationLeaf(value: 49)
    var referenced = @[IsolationChoice(hasRef: true, leaf: outside)]
    expect(IsolationError):
      var isolated = isolateRuntime(move referenced)
      discard isolated.extract()
    check outside.value == 49

  test "container checks reject internal repeated refs and cycles":
    var leaf = IsolationLeaf(value: 50)
    var repeated = @[leaf, move leaf]
    expect(IsolationError):
      var isolated = isolateRuntime(move repeated)
      discard isolated.extract()
    var cycle = IsolationCycle()
    cycle.children.add cycle
    defer:
      cycle.children.setLen(0)
    var cyclic = @[cycle]
    expect(IsolationError):
      var isolated = isolateRuntime(move cyclic)
      discard isolated.extract()
    check cycle.children[0] == cycle

  test "arrays with enum indexes retain uniquely owned elements":
    type Index = enum
      first, second
    var values: array[Index, IsolationLeaf]
    values[first] = IsolationLeaf(value: 51)
    values[second] = IsolationLeaf(value: 52)
    var isolated = isolateRuntime(move values)
    let recovered = isolated.extract()
    check recovered[first].value == 51
    check recovered[second].value == 52

type
  NonCopy = object

  Foo = object of RootObj
    id: int

  BarImpl = object of Foo
    value: int
    # thr: Thread[int]
    # ch: Chan[int]

proc `=copy`*(a: var NonCopy, b: NonCopy) {.error.}

method test*(obj: Foo) {.base.} =
  echo "foo: ", obj.repr

method test*(obj: BarImpl) =
  echo "barImpl: ", obj.repr

proc newBarImpl*(): SharedPtr[BarImpl] =
  var thr = BarImpl(id: 1234)
  result = newSharedPtr(thr)

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
  when false:
    test "test foos":
      var b = BarImpl(id: 34, value: 101)
      var a: Foo
      a = b
      b.test()
      a.test()
      echo "a: ", a.repr

    test "test lets":
      let b = BarImpl(id: 34, value: 101)
      let a: Foo = b
      let c: Foo = a
      b.test()
      a.test()
      c.test()
      echo "a: ", a.repr

  test "test ptr":
    # var b = BarImpl(id: 34, value: 101)
    var bp: ptr BarImpl = cast[ptr BarImpl](allocShared0(sizeof(BarImpl)))

    bp[] = BarImpl(id: 34, value: 101)
    var ap: ptr Foo = bp

    bp[].test()
    ap[].test()
    check bp[].id == 34
    check bp[].value == 101
    let d = Foo(id: 56)
    d.test()

    proc testValue(bar: var BarImpl): int =
      bar.value

    check bp[].testValue() == 101

  test "isolateRuntime sharedPointer":
    echo "test"

    # let test = getCurrentFoo()
    # echo "test: ", test
    # check not test.isNil
    # check test[].id == 1234
