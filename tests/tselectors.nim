import std/[options, strutils, unittest]

import sigils/core
import sigils/selectors
import sigils/signals
import sigils/slots

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
    builtWithNew: bool

  PlainThing = ref object of DynamicAgent
    value: int

  BaseWidget = ref object of DynamicAgent
    log: seq[string]

  DerivedWidget = ref object of BaseWidget

  SelectorPayload = object
    x: int
    y: int

method parseInteger(text: string): int {.selector.}
method canPerformCommand(command: string): bool {.selector.}
method hitTest(x, y: int): string {.selector.}
method isFirstResponder(): bool {.selector.}
method payloadTotal(payload: SelectorPayload): int {.selector.}

proc new(_: typedesc[ExportedThing], value: int): ExportedThing =
  ExportedThing(value: value + 1, builtWithNew: true)

protocol TextFieldDelegate:
  method validateText(text: string): bool
  method textDidCommit(text: string) {.optional.}
  method placeholderText(): string {.optional.}

protocol StrictTextFieldDelegate:
  includes TextFieldDelegate

  method selectionRange(): string

protocol TitledProtocol:
  property title -> string

protocol CaptionedViewProtocol from View:
  property caption -> string
  proc captionWillChange(view: View) {.signal.}

  proc applyCaption(self: View, value: string) {.slot.} =
    self.name = value

  method caption(self: View): string =
    self.name

  method setCaption(self: View, value: string) =
    self.name = value

protocol WindowLifecycleProtocolInternal:
  method windowShouldSetContentView*(view: View): bool {.optional.}
  proc windowWillSetContentView*(window: Window, view: View) {.signal.}
  proc windowDidSetContentView*(window: Window, view: View) {.signal.}
  proc rememberContentView*(view: View) {.slot.}

protocol StrictWindowLifecycleProtocol:
  includes WindowLifecycleProtocolInternal

  method windowIdentifier*(): string
  proc windowDidBecomeKey*(window: Window) {.signal.}
  proc rememberWindowKey*() {.slot.}

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

proc rememberContentView(self: TextController, view: View) {.slot.} =
  self.lastCommand = view.name

proc rememberWindowKey(self: TextController) {.slot.} =
  self.lastCommand = "key"

method controllerSelectionRange(self: TextController): string {.selector.} =
  $self.parsed

method viewTitle(self: View): string {.selector.} =
  self.name

method viewSetTitle(self: View, value: string) {.selector.} =
  self.name = value

protocol DefaultTextField of TextFieldDelegate:
  method validateText(self: TextController, text: string): bool =
    text.strip.len > 0

  method textDidCommit(self: TextController, text: string) =
    self.lastCommand = text

protocol ExportedThingProtocol from ExportedThing:
  method exportedValue*(self: ExportedThing): int =
    self.value

protocol PlainThingProtocol from PlainThing:
  method plainValue*(self: PlainThing): int =
    self.value

protocol WidgetEvents:
  method handleWidgetEvent*(event: string): string

protocol BaseWidgetEvents of WidgetEvents:
  method handleWidgetEvent(self: BaseWidget, event: string): string =
    self.log.add "base:" & event
    "base:" & event

protocol MiddleWidgetEvents of WidgetEvents:
  method handleWidgetEvent(self: DerivedWidget, event: string): string =
    self.log.add "middle:" & event
    let next = self.performNext(handleWidgetEvent, event)
    if next.isSome:
      "middle(" & next.get() & ")"
    else:
      "middle"

protocol DerivedWidgetEvents of WidgetEvents:
  method handleWidgetEvent(self: DerivedWidget, event: string): string =
    self.log.add "derived:" & event
    let next = self.performNext(handleWidgetEvent, event)
    if next.isSome:
      "derived(" & next.get() & ")"
    else:
      "derived"

method viewHitTest(self: View, x, y: int): string {.selector.} =
  if x >= self.x and y >= self.y and
      x < self.x + self.width and y < self.y + self.height:
    result = self.name

method windowFirstResponder(self: Window): bool {.selector.} =
  self.focused

method controllerPayloadTotal(
    self: TextController, payload: SelectorPayload
): int {.selector.} =
  payload.x + payload.y

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

  test "forwarding target handles unhandled selectors":
    let
      field = TextField(text: "17")
      controller = TextController()
      parseName = selectorName(parseInteger)

    check controller.addMethod(parseInteger, parseController)
    field.setForwardingTarget(proc(
        self: DynamicAgent, selector: SigilName
    ): DynamicAgent =
      if selector == parseName:
        result = controller
    )

    check field.respondsTo(parseInteger)
    check field.parseInteger(field.text) == 17
    check controller.parsed == 17

  test "resolve method can lazily install a selector":
    let
      field = TextField(text: "19")
      parseName = selectorName(parseInteger)

    field.setResolveMethod(proc(self: DynamicAgent, selector: SigilName): bool =
      if selector == parseName:
        result = self.addMethod(parseInteger, parseField)
    )

    check field.methodStack(parseInteger).len == 0
    check field.parseInteger(field.text) == 19
    check field.methodStack(parseInteger).len == 1

  test "forward invocation can handle a selector directly":
    let
      field = TextField(text: "23")
      parseName = selectorName(parseInteger)

    field.setForwardInvocation(proc(
        self: DynamicAgent, invocation: var Invocation
    ): bool =
      if invocation.selector == parseName:
        invocation.setResult(parseInt(invocation.argsAs(string)) + 1)
        result = true
    )

    check field.parseInteger(field.text) == 24

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

  when sigilsClosuresEnabled:
    test "selector closure methods capture state":
      let field = TextField(text: "field")
      var offset = 10

      let old = field.replaceMethod(parseInteger) do(self: TextField,
          text: string) -> int:
        parseInt(text) + offset + self.text.len

      check old.isNil
      check field.parseInteger("7") == 22

      offset = 2
      check field.parseInteger("7") == 14

    test "selector closure methods can return void":
      let controller = TextController()
      let prefix = "saved:"

      let old = controller.replaceMethod(textDidCommit) do(self: TextController,
          text: string):
        self.lastCommand = prefix & text

      check old.isNil
      controller.textDidCommit("draft")
      check controller.lastCommand == "saved:draft"

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

  test "method lookup exposes local method stacks":
    let
      field = TextField()
      selector = parseInteger

    check field.localMethod(selector).isNil
    check field.methodFor(selector).isNil
    check field.methodStack(selector).len == 0

    check field.addMethod(parseInteger, parseField)
    check not field.localMethod(selector).isNil
    check not field.methodFor(selector.name).isNil
    check field.methodStack(selector).len == 1

    let token = field.pushMethod(parseInteger, incrementNextResult)
    check field.methodStack(selector).len == 2
    check token.popMethod()
    check field.methodStack(selector).len == 1

  when sigilsClosuresEnabled:
    test "pushMethod accepts a selector closure override":
      let field = TextField()
      var offset = 5

      discard field.addMethod(parseInteger, parseField)

      let token = field.pushMethod(parseInteger) do(self: TextField,
          text: string) -> int:
        parseInt(text) + offset

      check field.parseInteger("7") == 12

      offset = 1
      check field.parseInteger("7") == 8
      check token.popMethod()
      check field.parseInteger("7") == 7

  test "direct selector send raises when unhandled":
    let field = TextField(text: "21")

    expect UnhandledSelectorError:
      discard field.parseInteger(field.text)

  test "optional sends return handled state":
    let field = TextField()

    check field.trySend(parseInteger, "7").isNone
    check not field.sendIfHandled(parseInteger, "7")

    check field.addMethod(parseInteger, parseField)
    check field.trySend(parseInteger, "7").get() == 7
    check field.sendIfHandled(parseInteger, "7")

    let window = Window(focused: true)
    check window.trySend(isFirstResponder).isNone
    check window.addMethod(isFirstResponder, windowFirstResponder)
    check window.trySend(isFirstResponder).get()
    check window.sendIfHandled(isFirstResponder)

  test "local optional sends do not walk responder chain":
    let
      field = TextField(text: "11")
      controller = TextController()

    field.setNextResponder(controller)
    check controller.addMethod(parseInteger, parseController)

    check field.trySendLocal(parseInteger, field.text).isNone
    check not field.sendLocalIfHandled(parseInteger, field.text)
    check controller.parsed == 0

    check field.trySend(parseInteger, field.text).get() == 11
    check controller.parsed == 11

  test "local optional sends honor local selector hooks":
    let
      resolved = TextField(text: "13")
      forwarded = TextField(text: "17")
      controller = TextController()
      invocationField = TextField(text: "19")
      parseName = selectorName(parseInteger)

    resolved.setResolveMethod(proc(self: DynamicAgent,
        selector: SigilName): bool =
      if selector == parseName:
        result = self.addMethod(parseInteger, parseField)
    )

    check resolved.trySendLocal(parseInteger, resolved.text).get() == 13

    check controller.addMethod(parseInteger, parseController)
    forwarded.setForwardingTarget(proc(
        self: DynamicAgent, selector: SigilName
    ): DynamicAgent =
      if selector == parseName:
        result = controller
    )

    check forwarded.trySendLocal(parseInteger, forwarded.text).get() == 17
    check controller.parsed == 17

    invocationField.setForwardInvocation(proc(
        self: DynamicAgent, invocation: var Invocation
    ): bool =
      if invocation.selector == parseName:
        invocation.setResult(parseInt(invocation.argsAs(string)) + 1)
        result = true
    )

    check invocationField.trySendLocal(parseInteger, invocationField.text).get() == 20

  test "local forwarding targets do not walk their responder chain":
    let
      field = TextField(text: "23")
      forwardingTarget = TextController()
      downstream = TextController()
      parseName = selectorName(parseInteger)

    forwardingTarget.setNextResponder(downstream)
    check downstream.addMethod(parseInteger, parseController)
    field.setForwardingTarget(proc(
        self: DynamicAgent, selector: SigilName
    ): DynamicAgent =
      if selector == parseName:
        result = forwardingTarget
    )

    check field.trySendLocal(parseInteger, field.text).isNone
    check downstream.parsed == 0
    check field.trySend(parseInteger, field.text).get() == 23
    check downstream.parsed == 23

  test "first selector send preserves object payload":
    let controller = TextController()
    check controller.addMethod(payloadTotal, controllerPayloadTotal)
    check controller.payloadTotal(SelectorPayload(x: 3, y: 4)) == 7

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

  test "protocol introspection splits required and optional requirements":
    check TextFieldDelegate.requiredRequirements.len == 1
    check TextFieldDelegate.optionalRequirements.len == 2
    check TextFieldDelegate.requiredSelectors == @[selectorName(validateText)]
    check selectorName(textDidCommit) in TextFieldDelegate.optionalSelectors
    check TextFieldDelegate.hasRequirement(validateText)
    check TextFieldDelegate.requirement(placeholderText).get().required == false
    check selectorName(validateText) in TextFieldDelegate.selectors

  test "protocol signal and slot declarations are metadata only":
    let window = Window()

    check WindowLifecycleProtocolInternal.requirements.len == 1
    check WindowLifecycleProtocolInternal.requiredRequirements.len == 0
    check WindowLifecycleProtocolInternal.signals.len == 2
    check WindowLifecycleProtocolInternal.slots.len == 1
    check toSigilName("windowWillSetContentView") in
        WindowLifecycleProtocolInternal.signalNames
    check toSigilName("rememberContentView") in
        WindowLifecycleProtocolInternal.slotNames
    check WindowLifecycleProtocolInternal.hasSignal(
      toSigilName("windowDidSetContentView")
    )
    check WindowLifecycleProtocolInternal.hasSlot(toSigilName("rememberContentView"))
    check WindowLifecycleProtocolInternal.protocolSignal(
      toSigilName("windowWillSetContentView")
    ).get().signature.len > 0
    check WindowLifecycleProtocolInternal.protocolSlot(
      toSigilName("rememberContentView")
    ).get().signature.len > 0

    check window.canConformTo(WindowLifecycleProtocolInternal)
    check window.missingRequirements(WindowLifecycleProtocolInternal).len == 0
    check SignalTypes.windowWillSetContentView(Window) is (View, )
    check SignalTypes.rememberContentView(TextController) is (View, )
    checkProtocolSlots(TextController, WindowLifecycleProtocolInternal)

    static:
      doAssert not compiles(checkProtocolSlots(Window,
          WindowLifecycleProtocolInternal))

  test "protocol includes inherit signals and slots":
    check StrictWindowLifecycleProtocol.requirements.len == 2
    check StrictWindowLifecycleProtocol.signals.len == 3
    check StrictWindowLifecycleProtocol.slots.len == 2
    check StrictWindowLifecycleProtocol.hasSignal(
      toSigilName("windowWillSetContentView")
    )
    check StrictWindowLifecycleProtocol.hasSignal(toSigilName("windowDidBecomeKey"))
    check StrictWindowLifecycleProtocol.hasSlot(toSigilName("rememberContentView"))
    check StrictWindowLifecycleProtocol.hasSlot(toSigilName("rememberWindowKey"))
    checkProtocolSlots(TextController, StrictWindowLifecycleProtocol)

  test "protocol signal declarations emit normal signals":
    let
      window = Window()
      view = View(name: "content")
      controller = TextController()

    connect(window, windowWillSetContentView, controller, rememberContentView)
    emit window.windowWillSetContentView(view)

    check controller.lastCommand == "content"

  test "protocol includes inherit requirements":
    let controller = TextController()

    check StrictTextFieldDelegate.requirements.len == 4
    check StrictTextFieldDelegate.hasRequirement(validateText)
    check StrictTextFieldDelegate.hasRequirement(selectionRange)
    check selectorName(selectionRange) in
        StrictTextFieldDelegate.requiredSelectors

    check controller.addMethod(validateText, validateRequired)
    check not controller.canConformTo(StrictTextFieldDelegate)
    check controller.addMethod(selectionRange, controllerSelectionRange)
    check controller.canConformTo(StrictTextFieldDelegate)
    check controller.adopt(StrictTextFieldDelegate)
    check StrictTextFieldDelegate.name in controller.adoptedProtocols

  test "property declarations create getter and setter selectors":
    let view = View(name: "old")

    check TitledProtocol.requirements.len == 2
    check TitledProtocol.hasRequirement(title)
    check TitledProtocol.hasRequirement(setTitle)

    discard view.replaceMethods(TitledProtocol, [
      title => viewTitle,
      setTitle => viewSetTitle,
    ])

    check view.title() == "old"
    view.setTitle("new")
    check view.title() == "new"
    check view.hasAdopted(TitledProtocol)

  test "default implementation protocols accept property declarations":
    let view = View(name: "old").withProto

    check CaptionedViewProtocol.requirements.len == 2
    check CaptionedViewProtocol.signals.len == 1
    check CaptionedViewProtocol.slots.len == 1
    check CaptionedViewProtocol.hasRequirement(caption)
    check CaptionedViewProtocol.hasRequirement(setCaption)
    check CaptionedViewProtocol.hasSignal(toSigilName("captionWillChange"))
    check CaptionedViewProtocol.hasSlot(toSigilName("applyCaption"))
    check SignalTypes.captionWillChange(View) is tuple[]
    check SignalTypes.applyCaption(View) is (string, )
    checkProtocolSlots(View, CaptionedViewProtocol)
    check view.hasAdopted(CaptionedViewProtocol)
    check view.caption() == "old"
    check view.captionWillChange().procName == toSigilName("captionWillChange")
    check view.unsafeWeakRef().captionWillChange().procName ==
        toSigilName("captionWillChange")
    view.applyCaption("applied")
    check view.caption() == "applied"
    view.setCaption("new")
    check view.caption() == "new"

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

  test "large method batch installs, dispatches, and removes":
    let controller = TextController()
    var implementation = ProtocolImplementation(
      protocol: SigilProtocol(name: toSigilName("LargePayloadProtocol")),
    )
    var selectors: seq[Selector[SelectorPayload, int]]

    for idx in 0 ..< 32:
      let selector = selector[SelectorPayload, int]("largePayload" & $idx)
      selectors.add selector
      implementation.protocol.requirements.add requirement(selector)
      implementation.methods.add selectorMethod(selector, controllerPayloadTotal)

    let old = controller.replaceMethods(implementation)

    check old.len == selectors.len
    for fn in old:
      check fn.isNil
    check controller.hasAdopted(implementation.protocol)
    check controller.perform(selectors[0], SelectorPayload(x: 3, y: 4)).get() == 7
    check controller.perform(selectors[^1], SelectorPayload(x: 5, y: 6)).get() == 11

    let removed = controller.removeMethods(implementation)

    check removed.len == selectors.len
    for fn in removed:
      check not fn.isNil
    check not controller.hasAdopted(implementation.protocol)
    check controller.perform(
      selectors[^1],
      SelectorPayload(x: 1, y: 2),
    ).isNone

  when sigilsClosuresEnabled:
    test "protocol method batches accept selector closures":
      let controller = TextController()
      let minimum = 4

      let old = controller.replaceMethods(TextFieldDelegate, [
        selectorMethod(validateText) do(self: TextController,
            text: string) -> bool:
        text.strip.len >= minimum,
        selectorMethod(textDidCommit) do(self: TextController, text: string):
        self.lastCommand = "closed:" & text,
      ])

      check old.len == 2
      check old[0].isNil
      check old[1].isNil
      check controller.hasAdopted(TextFieldDelegate)
      check not controller.validateText("abc")
      check controller.validateText("abcd")
      controller.textDidCommit("done")
      check controller.lastCommand == "closed:done"

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

  test "withProtocol installs a named implementation variant":
    let controller = TextController().withProtocol(DefaultTextField)

    check controller.hasAdopted(TextFieldDelegate)
    check controller.validateText("value")
    check not controller.validateText("")
    controller.textDidCommit("variant")
    check controller.lastCommand == "variant"

  test "withProto installs a generated default protocol":
    let thing = ExportedThing(value: 42).withProto

    check not thing.builtWithNew
    check thing.hasAdopted(ExportedThingProtocol)
    check thing.exportedValue == 42

  test "stacked protocol implementations can call the next selector method":
    let widget = DerivedWidget()
    discard widget.replaceMethods(BaseWidgetEvents.init())

    let middleTokens = widget.pushMethods(MiddleWidgetEvents.init())
    let tokens = widget.pushMethods(DerivedWidgetEvents.init())

    check tokens.len == 1
    check middleTokens.len == 1
    check widget.handleWidgetEvent("drag") == "derived(middle(base:drag))"
    check widget.log == @["derived:drag", "middle:drag", "base:drag"]
    check BaseWidget(widget).handleWidgetEvent("cast") ==
        "derived(middle(base:cast))"
    check widget.log == @[
      "derived:drag", "middle:drag", "base:drag", "derived:cast", "middle:cast",
      "base:cast"
    ]

    check tokens[0].popMethod()
    check widget.handleWidgetEvent("drop") == "middle(base:drop)"
    check middleTokens[0].popMethod()
    check widget.handleWidgetEvent("drop") == "base:drop"
    check widget.trySendNext(handleWidgetEvent, "drop").isNone

  test "newProto prefers a typedesc new overload":
    let thing = ExportedThing.newProto(value = 41)

    check thing.builtWithNew
    check thing.hasAdopted(ExportedThingProtocol)
    check thing.exportedValue == 42

  test "newProto falls back to ref object construction":
    let thing = PlainThing.newProto(value = 42)

    check thing.hasAdopted(PlainThingProtocol)
    check thing.plainValue == 42

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

  test "remove methods uninstalls selectors and protocol adoption":
    let field = TextField()

    check field.addMethod(parseInteger, parseField)
    check not field.removeMethod(parseInteger).isNil
    check field.localMethod(parseInteger).isNil
    check not field.respondsTo(parseInteger)

    let controller = TextController()
    discard controller.replaceMethods(TextFieldDelegate, [
      validateText => validateRequired,
      textDidCommit => controllerCommit,
    ])

    check controller.hasAdopted(TextFieldDelegate)
    let removed = controller.removeMethods(TextFieldDelegate)
    check removed.len == 3
    check not removed[0].isNil
    check not removed[1].isNil
    check removed[2].isNil
    check not controller.hasAdopted(TextFieldDelegate)
    check not controller.respondsTo(validateText)
    check not controller.respondsTo(textDidCommit)

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
