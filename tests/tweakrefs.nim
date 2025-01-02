import std/[unittest, sequtils]
import sigils
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
  test "subscribers freed":
    var x = Counter.new()

    block:
      var obj {.used.} = TestObj(val: 100)
      var y = Counter.new()

      # echo "Counter.setValue: ", "x: ", x.debugId, " y: ", y.debugId
      connect(x, valueChanged, y, setValue)

      check y.value == 0
      emit x.valueChanged(137)

      echo "x:subscribers: ", x.subscribers
      # echo "x:subscribed: ", x.subscribed
      echo "y:subscribers: ", y.subscribers
      # echo "y:subscribed: ", y.subscribed

      check y.subscribers.len() == 0
      check y.listening.len() == 1

      check x.subscribers["valueChanged".toSigilName].len() == 1
      check x.listening.len() == 0

      echo "block done"

    echo "finishing outer block "
    # check x.listening.len() == 0
    echo "x:subscribers: ", x.subscribers
    # echo "x:subscribed: ", x.subscribed
    # check x.subscribers["valueChanged"].len() == 0
    check x.subscribers.len() == 0
    check x.listening.len() == 0

    # check a.value == 0
    # check b.value == 137
    echo "done outer block"

  test "subscribers freed":
    var y = Counter.new()

    block:
      var obj {.used.} = TestObj(val: 100)
      var x = Counter.new()

      # echo "Counter.setValue: ", "x: ", x.debugId, " y: ", y.debugId
      connect(x, valueChanged, y, setValue)

      check y.value == 0
      emit x.valueChanged(137)

      echo "x:subscribers: ", x.subscribers
      # echo "x:subscribed: ", x.subscribed
      echo "y:subscribers: ", y.subscribers
      # echo "y:subscribed: ", y.subscribed

      check y.subscribers.len() == 0
      check y.listening.len() == 1

      check x.subscribers["valueChanged".toSigilName].len() == 1
      check x.listening.len() == 0

      echo "block done"

    echo "finishing outer block "
    # check x.listening.len() == 0
    echo "y:subscribers: ", y.subscribers
    # echo "y:subscribed: ", y.listening.mapIt(it)
    # check x.subscribers["valueChanged"].len() == 0
    check y.subscribers.len() == 0
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
  check x.subscribers.len() == 0
  check x.listening.len() == 0
  check x.unsafeGcCount() == 1
