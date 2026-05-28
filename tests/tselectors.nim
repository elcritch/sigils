import std/[options, strutils, unittest]

import sigils/selectors

type
  TextField = ref object of DynamicAgent
    text: string

  TextController = ref object of DynamicAgent
    parsed: int
    lastCommand: string

  View = ref object of DynamicAgent
    name: string
    x, y, width, height: int

  Window = ref object of DynamicAgent
    focused: bool

  ExportedThing = ref object of DynamicAgent
    value: int

method parseInteger(text: string): int {.selector.}
method canPerformCommand(command: string): bool {.selector.}
method hitTest(x, y: int): string {.selector.}
method isFirstResponder(): bool {.selector.}

protocol TextFieldDelegate:
  method validateText(text: string): bool
  method textDidCommit(text: string) {.optional.}
  method placeholderText(): string {.optional.}

method parseField(self: TextField, text: string): int {.selector.} =
  parseInt(text)

method parseController(self: TextController, text: string): int {.selector.} =
  self.parsed = parseInt(text)
  self.parsed

method parseDouble(self: TextField, text: string): int {.selector.} =
  parseInt(text) * 2

method validateRequired(self: TextController, text: string): bool {.selector.} =
  text.strip.len > 0

method validateDigitsOnly(self: TextField, text: string): bool {.selector.} =
  text.len > 0 and text.allCharsInSet({'0' .. '9'})

method controllerCommand(self: TextController,
    command: string): bool {.selector.} =
  result = command in ["submit:", "cancel:"]
  if result:
    self.lastCommand = command

method controllerCommit(self: TextController, text: string) {.selector.} =
  self.lastCommand = text

protocol DefaultTextField of TextFieldDelegate:
  method validateText(self: TextController, text: string): bool =
    text.strip.len > 0

  method textDidCommit(self: TextController, text: string) =
    self.lastCommand = text

protocol ExportedThingProtocol from ExportedThing:
  method exportedValue*(self: ExportedThing): int =
    self.value

method viewHitTest(self: View, x, y: int): string {.selector.} =
  if x >= self.x and y >= self.y and
      x < self.x + self.width and y < self.y + self.height:
    result = self.name

method windowFirstResponder(self: Window): bool {.selector.} =
  self.focused

proc incrementNextResult(
    self: DynamicAgent, invocation: var Invocation, next: DynamicMethod
) =
  check not next.isNil
  next(self, invocation)
  invocation.setResult(invocation.resultAs(int) + 1)

proc trimTextBeforeValidation(
    self: DynamicAgent, invocation: var Invocation, next: DynamicMethod
) =
  check not next.isNil
  let text = invocation.argsAs(string).strip
  var normalized = initInvocation(invocation.selector, text)
  next(self, normalized)
  check normalized.handled
  invocation.setResult(normalized.resultAs(bool))

suite "dynamic selectors":
  test "local method handles a typed selector":
    let field = TextField(text: "21")

    check field.addMethod(parseInteger, parseField)

    var value: int
    check field.respondsTo(parseInteger)
    check field.perform(parseInteger, field.text, value)
    check value == 21

    check field.perform(parseInteger, "34").get() == 34
    check field.parseInteger(field.text) == 21

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
    check field.parseInteger(field.text) == 13

  test "pushMethod swizzles and restores selector behavior":
    let field = TextField()

    discard field.addMethod(parseInteger, parseField)

    let token = field.pushMethod(parseInteger, incrementNextResult)

    check field.perform(parseInteger, "7").get() == 8
    check field.parseInteger("7") == 8
    check token.popMethod()
    check field.perform(parseInteger, "7").get() == 7

  test "replaceMethod swaps local selector implementation":
    let field = TextField()

    discard field.addMethod(parseInteger, parseField)

    let old = field.replaceMethod(parseInteger, parseDouble)

    check not old.isNil
    check field.perform(parseInteger, "9").get() == 18
    check field.parseInteger("9") == 18

  test "replaceMethods installs selector bindings in one batch":
    let field = TextField()

    let old = field.replaceMethods([
      parseInteger => parseField,
      validateText => validateDigitsOnly,
    ])

    check old.len == 2
    check old[0].isNil
    check old[1].isNil
    check field.parseInteger("9") == 9
    check field.validateText("123")
    check not field.validateText("abc")

  test "direct selector send raises when unhandled":
    let field = TextField(text: "21")

    expect UnhandledSelectorError:
      discard field.parseInteger(field.text)

  test "protocol macro declares selectors and runtime requirements":
    let controller = TextController()

    check TextFieldDelegate.requirements.len == 3
    check TextFieldDelegate.requirements[0].required
    check not TextFieldDelegate.requirements[1].required
    check not controller.canConformTo(TextFieldDelegate)
    check not controller.conformsTo(TextFieldDelegate)

    expect ProtocolConformanceError:
      discard controller.adopt(TextFieldDelegate)

    check controller.addMethod(validateText, validateRequired)
    check controller.canConformTo(TextFieldDelegate)
    check controller.conformsTo(TextFieldDelegate)
    check not controller.hasAdopted(TextFieldDelegate)
    check controller.adopt(TextFieldDelegate)
    check controller.hasAdopted(TextFieldDelegate)

    expect UnhandledSelectorError:
      discard controller.placeholderText()

  test "replaceMethods can install and adopt a protocol":
    let controller = TextController()

    let old = controller.replaceMethods(TextFieldDelegate, [
      validateText => validateRequired,
      textDidCommit => controllerCommit,
    ])

    check old.len == 2
    check old[0].isNil
    check old[1].isNil
    check controller.hasAdopted(TextFieldDelegate)
    check controller.validateText("customer@example.com")
    controller.textDidCommit("saved")
    check controller.lastCommand == "saved"

  test "named protocol block creates a typedesc init proc":
    let controller = TextController()

    let old = controller.replaceMethods(DefaultTextField.init())

    check old.len == 2
    check old[0].isNil
    check old[1].isNil
    check controller.hasAdopted(TextFieldDelegate)
    check controller.validateText("value")
    check not controller.validateText("")
    controller.textDidCommit("named")
    check controller.lastCommand == "named"

  test "combined protocol block creates a proto proc":
    let thing = ExportedThing(value: 42)

    discard thing.replaceMethods(ExportedThing.proto())

    check thing.hasAdopted(ExportedThingProtocol)
    check thing.exportedValue == 42

  test "implement block creates a reusable protocol implementation":
    let
      controller = TextController()
      delegateImpl = implement(TextFieldDelegate):
        method validateText(self: TextController, text: string): bool =
          text.strip.len > 0

        method textDidCommit(self: TextController, text: string) =
          self.lastCommand = text

    let old = controller.replaceMethods(delegateImpl)

    check old.len == 2
    check old[0].isNil
    check old[1].isNil
    check controller.hasAdopted(TextFieldDelegate)
    check controller.validateText("value")
    controller.textDidCommit("committed")
    check controller.lastCommand == "committed"

  test "implement block can install directly on an object":
    let controller = TextController()

    let old = controller.implement(TextFieldDelegate):
      method validateText(self: TextController, text: string): bool =
        text.strip.len > 0

      method textDidCommit(self: TextController, text: string) =
        self.lastCommand = text

    check old.len == 2
    check old[0].isNil
    check old[1].isNil
    check controller.hasAdopted(TextFieldDelegate)
    check not controller.validateText("")
    controller.textDidCommit("direct")
    check controller.lastCommand == "direct"

  test "protocol method batch must satisfy required selectors":
    let controller = TextController()

    expect ProtocolConformanceError:
      discard controller.replaceMethods(TextFieldDelegate, [
        textDidCommit => controllerCommit,
      ])

    check not controller.respondsTo(textDidCommit)
    check not controller.hasAdopted(TextFieldDelegate)

  test "text field can delegate validation to a controller":
    let
      field = TextField(text: "")
      controller = TextController()

    field.setNextResponder(controller)
    check controller.addMethod(validateText, validateRequired)

    check field.canConformTo(TextFieldDelegate)
    check field.respondsTo(validateText)
    check field.perform(validateText, field.text).get() == false
    check field.perform(validateText, "customer@example.com").get() == true
    check field.validateText("customer@example.com") == true

  test "local validation overrides delegated GUI policy":
    let
      field = TextField()
      controller = TextController()

    field.setNextResponder(controller)
    check controller.addMethod(validateText, validateRequired)
    check field.addMethod(validateText, validateDigitsOnly)

    check field.perform(validateText, "abc").get() == false
    check field.perform(validateText, "1234").get() == true
    check field.validateText("1234") == true

  test "validation wrapper can normalize text before calling next method":
    let field = TextField()

    discard field.addMethod(validateText, validateDigitsOnly)

    check field.perform(validateText, " 42 ").get() == false

    let token = field.pushMethod(validateText, trimTextBeforeValidation)
    check field.perform(validateText, " 42 ").get() == true
    check field.validateText(" 42 ") == true
    check token.popMethod()
    check field.perform(validateText, " 42 ").get() == false

  test "menu command walks the GUI responder chain":
    let
      button = TextField(text: "Save")
      toolbar = View(name: "toolbar")
      window = Window()
      controller = TextController()

    button.setNextResponder(toolbar)
    toolbar.setNextResponder(window)
    window.setNextResponder(controller)

    check controller.addMethod(canPerformCommand, controllerCommand)

    check button.respondsTo(canPerformCommand)
    check button.perform(canPerformCommand, "submit:").get() == true
    check button.canPerformCommand("submit:") == true
    check controller.lastCommand == "submit:"
    check button.perform(canPerformCommand, "delete:").get() == false

    window.clearNextResponder()
    check not button.respondsTo(canPerformCommand)
    check button.perform(canPerformCommand, "submit:").isNone
    expect UnhandledSelectorError:
      discard button.canPerformCommand("submit:")

  test "view hit testing uses named tuple selector arguments":
    let view = View(name: "content", x: 10, y: 20, width: 80, height: 40)

    check view.addMethod(hitTest, viewHitTest)
    check view.perform(hitTest, (x: 10, y: 20)).get() == "content"
    check view.hitTest(10, 20) == "content"
    check view.perform(hitTest, (x: 89, y: 59)).get() == "content"
    check view.perform(hitTest, (x: 90, y: 59)).get() == ""
    check view.perform(hitTest, (x: 9, y: 20)).get() == ""

  test "window first responder query uses a zero argument selector":
    let window = Window(focused: true)

    check window.addMethod(isFirstResponder, windowFirstResponder)
    check window.perform(isFirstResponder, ()).get() == true
    check window.isFirstResponder() == true
