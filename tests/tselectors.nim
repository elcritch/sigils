import std/[options, strutils, unittest]

import sigils/selectors

type
  TextField = ref object of DynamicAgent
    text: string

  TextController = ref object of DynamicAgent
    parsed: int

method parseInteger(text: string): int {.selector.}

method parseField(self: TextField, text: string): int {.selector.} =
  parseInt(text)

method parseController(self: TextController, text: string): int {.selector.} =
  self.parsed = parseInt(text)
  self.parsed

method parseDouble(self: TextField, text: string): int {.selector.} =
  parseInt(text) * 2

proc incrementNextResult(
    self: DynamicAgent, invocation: var Invocation, next: DynamicMethod
) =
  check not next.isNil
  next(self, invocation)
  invocation.setResult(invocation.resultAs(int) + 1)

suite "dynamic selectors":
  test "local method handles a typed selector":
    let field = TextField(text: "21")

    check field.addMethod(parseInteger, parseField)

    var value: int
    check field.respondsTo(parseInteger)
    check field.perform(parseInteger, field.text, value)
    check value == 21

    check field.perform(parseInteger, "34").get() == 34

  test "unhandled selector forwards through responder chain":
    let
      field = TextField(text: "13")
      controller = TextController()

    field.setNextResponder(controller)

    check controller.addMethod(parseInteger, parseController)

    var value: int
    check field.respondsTo(parseInteger)
    check field.perform(parseInteger, field.text, value)
    check value == 13
    check controller.parsed == 13

  test "pushMethod swizzles and restores selector behavior":
    let field = TextField()

    discard field.addMethod(parseInteger, parseField)

    let token = field.pushMethod(parseInteger, incrementNextResult)

    check field.perform(parseInteger, "7").get() == 8
    check token.popMethod()
    check field.perform(parseInteger, "7").get() == 7

  test "replaceMethod swaps local selector implementation":
    let field = TextField()

    discard field.addMethod(parseInteger, parseField)

    let old = field.replaceMethod(parseInteger, parseDouble)

    check not old.isNil
    check field.perform(parseInteger, "9").get() == 18
