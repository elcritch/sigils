import sigils/signals
import sigils/slots
import sigils/core

import unittest
import std/sequtils

type
  Sigil*[T] = ref object of Agent
    value: T

proc changed[T](r: Sigil[T], val: T) {.signal.}

proc setValue[T](r: Sigil[T], val: T) {.slot.} =
  r.value = val

template `<-`[T](r: Sigil[T], val: T) =
  if r.value != val:
    emit r.changed(val)

template reactive[T](x: T): Sigil[T] =
  block:
    let r = Sigil[T](value: x)
    r.connect(changed, r, setValue)
    r

template computed[T](blk: untyped): Sigil[T] =
  block:
    let res = Sigil[T]()
    func comp(res: Sigil[T]): T {.slot.} =
      res.value = block:
        template `{}`(r: Sigil): auto {.inject.} =
          echo "DO"
          r.value
        `blk`
    let _ = block:
      template `{}`(r: Sigil): auto {.inject.} =
        echo "SETUP"
        r.connect(changed, res, comp, acceptVoidSlot = true)
        r.value
      blk
    res

suite "reactive examples":
  test "reactive":
    let
      x = Sigil[int](value: 5)
      y = Sigil[int]()
    
    proc computed[T](self: Sigil[T], val: T) {.slot.} =
      self.value = val * 2
    x.connect(changed, y, computed)
    emit x.changed(2)
    check y.value == 4

  test "reactive wrapper":

    let
      x = reactive(5)
      y = computed[int]():
        2 * x{}

    check x.value == 5
    check y.value == 0
    x <- 2
    check y.value == 4
    x <- 2

  test "reactive wrapper trace executions":

    var cnt = Sigil[int](value: 0)

    let
      x = reactive(5)
      z = computed[int]():
        cnt.value.inc()
        8 * x{}

    check cnt.value == 1 # cnt is called from the `read` (`trace`) setup step
    echo "X: ", x.value,  " => Z: ", z.value, " (", cnt.value, ")"
    x <- 2
    echo "X: ", x.value,  " => Z: ", z.value, " (", cnt.value, ")"
    check z.value == 16
    x <- 2
    echo "X: ", x.value,  " => Z: ", z.value, " (", cnt.value, ")"
    check cnt.value == 2


