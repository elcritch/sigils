import sigils/reactive

import unittest
import std/sequtils

suite "reactive examples":

  test "reactive wrapper":

    let
      x = reactive(5)
      y = computed[int]():
        2 * x{}

    check x.val == 5
    check y.val == 0
    x <- 2
    check y.val == 4
    # x <- 2
