import sigils/reactive

import unittest
import std/sequtils

suite "reactive examples":

  test "reactive wrapper":

    let
      x = newSigil(5)
      y = computed[int]():
        2 * x{}

    when defined(sigilsDebug):
      x.debugName = "X"
      y.debugName = "Y"

    check x.val == 5
    check y.val == 10
    x <- 2
    check x.val == 2
    check y.val == 4
    # x <- 2

  test "reactive wrapper trace executions and side effects":

    var cnt = Sigil[int](val: 0)

    let
      x = newSigil(5)
      z = computed[int]():
        cnt.val.inc()
        8 * x{}

    when defined(sigilsDebug):
      x.debugName = "X"
      z.debugName = "Z"

    check cnt.val == 1 # cnt is called from the `read` (`trace`) setup step
    echo "X: ", x.val,  " => Z: ", z.val, " (", cnt.val, ")"
    x <- 2
    echo "X: ", x.val,  " => Z: ", z.val, " (", cnt.val, ")"
    check z.val == 16
    x <- 2
    echo "X: ", x.val,  " => Z: ", z.val, " (", cnt.val, ")"
    check cnt.val == 2

