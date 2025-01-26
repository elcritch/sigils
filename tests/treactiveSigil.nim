import sigils/reactive
import std/math

import unittest
import std/sequtils

template isNear*[T](a, b: T, eps = 1.0e-5): bool =
  let same = near(a, b, eps)
  if not same:
    checkpoint("a and b not almost equal: a: " & $a & " b: " & $b & " delta: " & $(a-b))
  same
  

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

  test "reactive wrapper multiple signals":
    let x = newSigil(5)
    let y = newSigil(false)

    when defined(sigilsDebug):
      x.debugName = "X"
      y.debugName = "Y"

    let z = computed[int]():
      if y{}:
        x{} * 2
      else:
        0

    when defined(sigilsDebug):
      z.debugName = "Z"

    check x.val == 5
    check y.val == false
    check z.val == 0

    y <- true
    check y.val == true
    check z.val == 10 # this starts failing

    x <- 2
    check x.val == 2
    check z.val == 4

    y <- false
    check y.val == false
    check z.val == 0

  test "reactive wrapper double inference":
    let x = newSigil(5)
    let y = newSigil(false)

    let z = computed[int]():
      if y{}:
        x{} * 2
      else:
        0

    let a = computed[string]():
      let myZ = z{}
      if y{}:
        fmt"The number is {myZ}"
      else:
        "There is no number"
    
    check x.val == 5
    check y.val == false
    check z.val == 0
    check a.val == "There is no number"
    
    y <- true
    check y.val == true
    check z.val == 10
    check a.val == "The number is 10"
    
    x <- 2
    check x.val == 2
    check z.val == 4
    check a.val == "The number is 4" # This fails. a does not get updated, because it does not **directly** rely on x. It does so indirectly by relying on z which relies on x
    
    y <- false
    check y.val == false
    check z.val == 0
    check a.val == "There is no number"

  test "reactive float test":
    let x = newSigil(3.14'f32)
    let y = newSigil(2.718'f32)

    let z = computed[float32]():
      x{} * y{}

    check isNear(x.val, 3.14)
    check isNear(y.val, 2.718)
    check isNear(z.val, 8.53452, 3)

    x <- 1.0
    check isNear(x.val, 1.0)
    check isNear(y.val, 2.718)
    check isNear(z.val, 2.718, 3)

  test "reactive float test":
    let x = newSigil(3.14'f64)
    let y = newSigil(2.718'f32)

    let z = computed[float]():
      x{} * y{}

    echo "X: ", x.val, " Z: ", z.val
    check isNear(x.val, 3.14)
    check isNear(y.val, 2.718)
    check isNear(z.val, 8.53451979637.float, 4)

    x <- 1.0
    check isNear(x.val, 1.0)
    check isNear(y.val, 2.718)
    check isNear(z.val, 2.718)
