import std/unittest

import ./smalltalk

suite "mini smalltalk interpreter":
  test "small arithmetic and message chaining":
    let program = parseProgram("""
      a := 10.
      b := 3.
      sum := a add: b add: 2.
      message := "sum=" add: sum asString.
      isSmall := sum lt: 20.
      same := sum eq: 15.
    """)

    var runtime = newRuntime()
    discard runtime.run(program)

    check runtime.getVar("a").toInt() == 10
    check runtime.getVar("b").toInt() == 3
    check runtime.getVar("sum").toInt() == 15
    check runtime.getVar("message").toString() == "sum=15"
    check runtime.getVar("isSmall").toBool() == true
    check runtime.getVar("same").toBool() == true

  test "run source helper returns last value":
    let result = runSource("a := 2.\n b := 3.\n a add: b.")
    check result.lastValue.toInt() == 5
    check result.runtime.getVar("a").toInt() == 2
    check result.runtime.getVar("b").toInt() == 3
