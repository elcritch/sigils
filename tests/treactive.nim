import sigils/signals
import sigils/slots
import sigils/core

import unittest
import std/sequtils

type
  Reactive*[T] = ref object of Agent
    value: T

proc changed[T](tp: Reactive[T], val: T) {.signal.}

template `{}`[T](r: Reactive[T]): T =
  r.value

template `set=`[T](r: Reactive[T], val: T) =
  emit r.changed(val)

suite "reactive examples":
  test "reactive":
    let
      x = Reactive[int](value: 5)
      y = Reactive[int]()
    
    proc computed[T](self: Reactive[T], val: T) {.slot.} =
      self.value = val * 2
    x.connect(changed, y, computed)

    emit x.changed(2)
    # echo "Y: ", y.value
    check y.value == 4

    # const x = signal(5)
    # const double = computed(() => x()*2)
    # x.set(2)
    # // double is now 4

  test "reactive wrapper":

    template reactive[T](x: T): Reactive[T] =
      Reactive[T](value: x)
    template computed[T](args: varargs[Reactive[T]], blk: typed): Reactive[T] =
      block:
        let r = Reactive[T]()
        proc comp(res: Reactive[T]): T {.slot.} =
          res.value = block:
              `blk`
        for arg in args:
          echo "ARG: ", arg.repr
          arg.connect(changed, r, comp, acceptVoidSlot = true)
        r
      
    let
      x = reactive(5)
      y = computed[int](x):
        2 * x{}
    
    printConnections(x)

    x.set= 2
    echo "X: ", x.value
    echo "Y: ", y.value
    check y.value == 4

