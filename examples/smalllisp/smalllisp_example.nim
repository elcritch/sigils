import std/[tables, unittest]

import ./smalllisp
import sigils/selectors

proc stDouble(
    self: SmalltalkValue, args: seq[SmalltalkValue]
): SmalltalkValue =
  if args.len != 0:
    raise newException(SmalltalkError, "double expects no arguments")
  newSmalltalkNumber(self.toInt() * 2)

suite "mini smalllisp smalltalk interpreter":
  test "prefix syntax and recursive message chaining":
    let program = parseProgram("""
      (set a 10)
      (set b 3)
      (set sum (add a (add b 2)))
      (set message (add "sum=" (asString sum)))
      (set isSmall (lt sum 20))
      (set same (eq sum 15))
    """)

    var runtime = newRuntime()
    discard runtime.run(program)

    check runtime.getVar("a").toInt() == 10
    check runtime.getVar("b").toInt() == 3
    check runtime.getVar("sum").toInt() == 15
    check runtime.getVar("message").toString() == "sum=15"
    check runtime.getVar("isSmall").toBool() == true
    check runtime.getVar("same").toBool() == true

  test "runSource helper returns last value":
    let result = runSource("(set a 2)\n(set b 3)\n(add a b)")
    check result.lastValue.toInt() == 5
    check result.runtime.getVar("a").toInt() == 2
    check result.runtime.getVar("b").toInt() == 3

  test "message sends dispatch by runtime selector name":
    var runtime = newRuntime()
    let value = newSmalltalkNumber(4)
    discard value.addMethod(
      selector[seq[SmalltalkValue], SmalltalkValue]("double"),
      toDynamicMethod(stDouble),
    )
    runtime.vars["value"] = value

    let result = runtime.run(parseProgram("(double value)"))

    check result.toInt() == 8
