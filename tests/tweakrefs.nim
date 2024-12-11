
import std/[unittest, sequtils]
import sigils

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

type
  TestObj = object
    val: int

proc `=destroy`*(obj: TestObj) =
  echo "destroying test object: ", obj.val


suite "agent weak refs":
  test "subscribers freed":
    var x = Counter.new()
    
    block:
      var obj {.used.} = TestObj(val: 100)
      var y = Counter.new()

      echo "Counter.setValue: ", "x: ", x.debugId, " y: ", y.debugId
      connect(x, valueChanged,
              y, setValue)

      check y.value == 0
      emit x.valueChanged(137)

      echo "x:subscribers: ", x.subscribers
      # echo "x:subscribed: ", x.subscribed
      echo "y:subscribers: ", y.subscribers
      # echo "y:subscribed: ", y.subscribed

      check y.subscribers.len() == 0
      check y.subscribedTo.len() == 1

      check x.subscribers["valueChanged"].len() == 1
      check x.subscribedTo.len() == 0

      echo "block done"
    
    echo "finishing outer block "
    # check x.subscribedTo.len() == 0
    echo "x:subscribers: ", x.subscribers
    # echo "x:subscribed: ", x.subscribed
    # check x.subscribers["valueChanged"].len() == 0
    check x.subscribers.len() == 0
    check x.subscribedTo.len() == 0

    # check a.value == 0
    # check b.value == 137
    echo "done outer block"

  test "subscribers freed":
    var y = Counter.new()
    
    block:
      var obj {.used.} = TestObj(val: 100)
      var x = Counter.new()

      echo "Counter.setValue: ", "x: ", x.debugId, " y: ", y.debugId
      connect(x, valueChanged,
              y, setValue)

      check y.value == 0
      emit x.valueChanged(137)


      echo "x:subscribers: ", x.subscribers
      # echo "x:subscribed: ", x.subscribed
      echo "y:subscribers: ", y.subscribers
      # echo "y:subscribed: ", y.subscribed

      check y.subscribers.len() == 0
      check y.subscribedTo.len() == 1

      check x.subscribers["valueChanged"].len() == 1
      check x.subscribedTo.len() == 0

      echo "block done"
    
    echo "finishing outer block "
    # check x.subscribedTo.len() == 0
    echo "y:subscribers: ", y.subscribers
    echo "y:subscribed: ", y.subscribedTo.mapIt(it)
    # check x.subscribers["valueChanged"].len() == 0
    check y.subscribers.len() == 0
    check y.subscribedTo.len() == 0

    # check a.value == 0
    # check b.value == 137
    echo "done outer block"

test "weak refs":
  when defined(gcOrc):
    const
      rcMask = 0b1111
      rcShift = 4      # shift by rcShift to get the reference counter
  else:
    const
      rcMask = 0b111
      rcShift = 3      # shift by rcShift to get the reference counter

  type
    RefHeader = object
      rc: int
      when defined(gcOrc):
        rootIdx: int # thanks to this we can delete potential cycle roots
                      # in O(1) without doubly linked lists

    Cell = ptr RefHeader

  template head[T](p: ref T): Cell =
    cast[Cell](cast[int](cast[pointer](p)) -% sizeof(RefHeader))
  template count(x: Cell): int =
    (x.rc shr rcShift)

  var x = Counter.new()
  echo "X::count: ", x.head().count()
  check x.head().count() == 0
  block:
    var obj {.used.} = TestObj(val: 100)
    var y = Counter.new()
    echo "X::count: ", x.head().count()
    check x.head().count() == 0

    echo "Counter.setValue: ", "x: ", x.debugId, " y: ", y.debugId
    connect(x, valueChanged,
            y, setValue)
    check x.head().count() == 0

    check y.value == 0
    emit x.valueChanged(137)
    echo "X::count:end: ", x.head().count()
    echo "Y::count:end: ", y.head().count()
    check x.head().count() == 1
  
  echo "done with y"
  echo "X::count: ", x.head().count()
  check x.subscribers.len() == 0
  check x.subscribedTo.len() == 0
  check x.head().count() == 0
