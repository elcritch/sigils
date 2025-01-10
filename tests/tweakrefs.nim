import std/[unittest, sequtils]

import sigils/signals
import sigils/slots
import sigils/core
import sigils/weakrefs

type
  Counter* = ref object of Agent
    value: int
    avg: int

  Originator* = ref object of Agent

proc change*(tp: Originator, val: int) {.signal.}

proc valueChanged*(tp: Counter, val: int) {.signal.}

proc someChange*(tp: Counter) {.signal.}

proc avgChanged*(tp: Counter, val: float) {.signal.}

proc setValue*(self: Counter, value: int) {.slot.} =
  echo "setValue! ", value
  if self.value != value:
    self.value = value
    emit self.valueChanged(value)

type TestObj = object
  val: int

var lastDestroyedTestObj = -1

proc `=destroy`*(obj: TestObj) =
  echo "destroying test object: ", obj.val
  lastDestroyedTestObj = obj.val

suite "agent weak refs":
  test "subcriptionsTable freed":
    var x = Counter.new()

    block:
      var obj {.used.} = TestObj(val: 100)
      var y = Counter.new()

      # echo "Counter.setValue: ", "x: ", x.debugId, " y: ", y.debugId
      connect(x, valueChanged, y, setValue)

      check y.value == 0
      emit x.valueChanged(137)

      echo "x:subcriptionsTable: ", x.subcriptionsTable
      # echo "x:subscribed: ", x.subscribed
      echo "y:subcriptionsTable: ", y.subcriptionsTable
      # echo "y:subscribed: ", y.subscribed

      check y.subcriptionsTable.len() == 0
      check y.listening.len() == 1

      check x.subcriptionsTable["valueChanged".toSigilName].len() == 1
      check x.listening.len() == 0

      echo "block done"

    echo "finishing outer block "
    # check x.listening.len() == 0
    echo "x:subcriptionsTable: ", x.subcriptionsTable
    # echo "x:subscribed: ", x.subscribed
    # check x.subcriptionsTable["valueChanged"].len() == 0
    check x.subcriptionsTable.len() == 0
    check x.listening.len() == 0

    # check a.value == 0
    # check b.value == 137
    echo "done outer block"

  test "subcriptionsTable freed":
    var y = Counter.new()

    block:
      var obj {.used.} = TestObj(val: 100)
      var x = Counter.new()

      # echo "Counter.setValue: ", "x: ", x.debugId, " y: ", y.debugId
      connect(x, valueChanged, y, setValue)

      check y.value == 0
      emit x.valueChanged(137)

      echo "x:subcriptionsTable: ", x.subcriptionsTable
      # echo "x:subscribed: ", x.subscribed
      echo "y:subcriptionsTable: ", y.subcriptionsTable
      # echo "y:subscribed: ", y.subscribed

      check y.subcriptionsTable.len() == 0
      check y.listening.len() == 1

      check x.subcriptionsTable["valueChanged".toSigilName].len() == 1
      check x.listening.len() == 0

      echo "block done"

    echo "finishing outer block "
    # check x.listening.len() == 0
    echo "y:subcriptionsTable: ", y.subcriptionsTable
    # echo "y:subscribed: ", y.listening.mapIt(it)
    # check x.subcriptionsTable["valueChanged"].len() == 0
    check y.subcriptionsTable.len() == 0
    check y.listening.len() == 0

    # check a.value == 0
    # check b.value == 137
    echo "done outer block"

  test "refcount":
    type TestRef = ref TestObj

    var x = TestRef(val: 33)
    echo "X::count: ", x.unsafeGcCount()
    check x.unsafeGcCount() == 1
    block:
      let y = x
      echo "X::count: ", x.unsafeGcCount()
      check x.unsafeGcCount() == 2
      check y.unsafeGcCount() == 2
    echo "X::count: ", x.unsafeGcCount()
    check x.unsafeGcCount() == 1
    var y = move x
    echo "y: ", repr y
    check lastDestroyedTestObj != 33
    check x.isNil
    check y.unsafeGcCount() == 1

  test "weak refs":
    var x = Counter.new()
    echo "X::count: ", x.unsafeGcCount()
    check x.unsafeGcCount() == 1
    block:
      var obj {.used.} = TestObj(val: 100)
      var y = Counter.new()
      echo "X::count: ", x.unsafeGcCount()
      check x.unsafeGcCount() == 1

      # echo "Counter.setValue: ", "x: ", x.debugId, " y: ", y.debugId
      connect(x, valueChanged, y, setValue)
      check x.unsafeGcCount() == 1

      check y.value == 0
      emit x.valueChanged(137)
      echo "X::count:end: ", x.unsafeGcCount()
      echo "Y::count:end: ", y.unsafeGcCount()
      check x.unsafeGcCount() == 2

      # var xx = x
      # check x.unsafeGcCount() == 2

    echo "done with y"
    echo "X::count: ", x.unsafeGcCount()
    check x.subcriptionsTable.len() == 0
    check x.listening.len() == 0
    check x.unsafeGcCount() == 1

type
  Foo = object of RootObj
    value: int

  FooBar = object of Foo

method test(obj: Foo) {.base.} =
  echo "test foos! value: ", obj.value

method test(obj: FooBar) =
  echo "test foobar! value: ", obj.value

suite "check object methods":
  test "methods":
    let f = Foo(value: 1)
    let fb = FooBar(value: 2)
    f.test()
    fb.test()
    let f1 = fb
    f1.test()
    check f.value == 1
