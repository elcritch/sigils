# Selectors

Selectors are Sigils' dynamic dispatch layer. Use signals when you want to broadcast that something happened. Use selectors when you want to ask one object to perform named behavior and optionally return a value.

They are useful for delegate APIs, command routing, responder chains, hit testing, validation, parsing policies, and small runtime overrides.

## Basic Use

Import `sigils` or `sigils/selectors`, then define objects that inherit from `DynamicAgent`.

```nim
import std/[options, strutils]
import sigils/selectors

type
  TextField = ref object of DynamicAgent
    text: string

  TextController = ref object of DynamicAgent
    parsed: int
```

Declare a selector with a method that has no receiver. This creates a typed selector value and a direct-send helper.

```nim
method parseInteger(text: string): int {.selector.}
```

Implement selector behavior with a receiver. The implementation does not have to use the same Nim proc name as the selector. You bind it to a selector at runtime.

```nim
method parseField(self: TextField, text: string): int {.selector.} =
  parseInt(text)

let field = TextField(text: "21")

discard field.addMethod(parseInteger, parseField)

doAssert field.respondsTo(parseInteger)
doAssert field.perform(parseInteger, field.text).get() == 21
doAssert field.parseInteger(field.text) == 21
```

`perform` returns an `Option[R]`. The direct-send form, such as `field.parseInteger("21")`, is for required sends and raises `UnhandledSelectorError` if no object handles the selector.

## Optional Sends

Use optional sends when it is valid for no object to handle the selector.

```nim
let value = field.trySend(parseInteger, "34")
if value.isSome:
  echo value.get()

if field.sendIfHandled(parseInteger, "55"):
  echo "parsed"
```

The local variants, `performLocal`, `trySendLocal`, and `sendLocalIfHandled`, do not walk the responder chain. They still honor local method resolution and local forwarding hooks.

## Responder Chains

Selectors can walk from one object to the next until a responder handles the invocation.

```nim
method parseController(self: TextController, text: string): int {.selector.} =
  self.parsed = parseInt(text)
  self.parsed

let
  field = TextField(text: "13")
  controller = TextController()

field.setNextResponder(controller)
discard controller.addMethod(parseInteger, parseController)

doAssert field.respondsTo(parseInteger)
doAssert field.parseInteger(field.text) == 13
doAssert controller.parsed == 13
```

This is the shape you want for UI-style behavior such as "can this command be performed?" A button can ask its view, window, and controller in order, and the first object with an answer handles it.

## Installing and Replacing Methods

`DynamicAgent` stores methods per selector.

```nim
discard field.addMethod(parseInteger, parseField)

let old = field.replaceMethod(parseInteger, parseField)
discard field.removeMethod(parseInteger)
```

Use `addMethod` when installing should fail if the object already has a local handler. Use `replaceMethod` when overriding is intentional. `removeMethod` removes all local methods for that selector.

With `-d:sigilsClosures`, you can install a closure directly when behavior needs captured runtime state.

```nim
let bonus = 10
let old = field.replaceMethod(parseInteger) do(self: TextField, text: string) -> int:
  parseInt(text) + bonus
```

You can also install batches:

```nim
discard field.replaceMethods([
  parseInteger => parseField,
])
```

Closure methods work in batches too:

```nim
let minimum = 4
discard controller.replaceMethods(TextFieldDelegate, [
  selectorMethod(validateText) do(self: TextController, text: string) -> bool:
    text.strip.len >= minimum,
])
```

## Protocols

Protocols group selectors into runtime contracts. Required selectors must be handled before an object can adopt the protocol. Optional selectors are recorded but do not block adoption.

```nim
protocol TextFieldDelegate:
  method validateText(text: string): bool
  method textDidCommit(text: string) {.optional.}

method validateRequired(self: TextController, text: string): bool {.selector.} =
  text.strip.len > 0

method controllerCommit(self: TextController, text: string) {.selector.} =
  discard

let controller = TextController()

discard controller.replaceMethods(TextFieldDelegate, [
  validateText => validateRequired,
  textDidCommit => controllerCommit,
])

doAssert controller.hasAdopted(TextFieldDelegate)
doAssert controller.validateText("value")
```

Protocols support inheritance:

```nim
protocol StrictTextFieldDelegate:
  includes TextFieldDelegate

  method selectionRange(): string
```

They also support property declarations. A property creates getter and setter selectors.

```nim
protocol TitledView:
  property title -> string
```

That declares `title` and `setTitle`.

If a protocol should use protocol-qualified runtime selector names, opt in with `selectorScope: protocol`.

```nim
protocol ListViewDataSource {.selectorScope: protocol.}:
  method numberOfRows(listView: ListView): int {.optional.}
  method objectValueForRow(listView: ListView, row: int): string {.optional.}
```

The Nim selector symbols stay short (`numberOfRows`, `objectValueForRow`), but their runtime `SigilName` values are prefixed with the protocol name:

```nim
doAssert selectorName(numberOfRows) ==
  toSigilName("ListViewDataSource.numberOfRows")
```

This is runtime selector scoping, not a generated Nim namespace; `ListViewDataSource.numberOfRows` is not created. If two imported modules export the same short selector helper, use normal Nim module qualification to choose between them. `SigilName` is a `StackString[48]` by default; you can switch to regular strings with `-d:sigilsSigilNameString`.

Protocols may also list signals and slots that belong to the same conceptual surface. Protocol signals are generated as normal Sigils signals and recorded in `protocol.signals`. Explicit protocol slots are recorded in `protocol.slots` and can be checked with `checkProtocolSlots(Receiver, Protocol)` or `requireProtocolSlots(Receiver, Protocol)`. Neither signals nor slots affect `canConformTo` or `adopt`.

The first signal parameter is still the signal source type. Receiverless slot declarations describe the slot payload. A `protocol ... from Receiver` may use normal receiver-first slot implementations.

```nim
protocol WindowLifecycle:
  method windowShouldClose(): bool {.optional.}
  proc windowWillClose(window: Window) {.signal.}
  proc rememberClose() {.slot.}

checkProtocolSlots(WindowController, WindowLifecycle)
```

For event protocols, a signal declaration is enough. `connectProtocol` tries to connect every protocol signal to an observer slot with the same name and compatible payload type. Missing observer slots are ignored, which makes partial observers cheap.

```nim
protocol ListViewEvents:
  proc selectionDidChange(listView: ListView, sender: DynamicAgent) {.signal.}

protocol ListControllerEvents from ListController:
  includes ListViewEvents

  proc selectionDidChange(controller: ListController, sender: DynamicAgent) {.slot.} =
    controller.updatePreview()

let controller = ListController().withProto()
connectProtocol(listView, controller, ListViewEvents)
emit listView.selectionDidChange(controller)
```

Use `slotFor` when the slot implementation needs a different Nim name from the event:

```nim
protocol ViewLayoutInputSlots from View:
  includes ViewLayoutInputEvents

  proc markLayoutInputDirty(
      view: View, reason: LayoutInvalidationReason
  ) {.slotFor: layoutInputChanged.} =
    view.xLayoutDirty.incl reason
```

That connects `layoutInputChanged` to `markLayoutInputDirty` while keeping the public event name unchanged. `slotFor` implies a slot, so `{.slot.}` is not required on the same proc.

A receiver-bound `from Receiver` protocol implementation with body-level `includes`, or a named `protocol Variant of Events` implementation, may provide event slots. Those slot names are checked at compile time against the base protocol's signals, and their payload types must match.

`observeProtocol` is the same operation with observer-first argument order, which is useful for small GUI wrappers:

```nim
controller.observeProtocol(listView, ListViewEvents)
controller.unobserveProtocol(listView, ListViewEvents)
```

`disconnectProtocol` and `unobserveProtocol` remove the matching protocol subscriptions.

For delegate-style APIs, keep behavior selectors and observation events as separate protocols. `setProtocolDelegate` updates a `DynamicAgent` delegate field, adopts the behavior protocol on the new delegate, disconnects the old delegate's registered event observer, and connects the new one.

```nim
protocol ListViewDelegate:
  method shouldSelectRow(listView: ListView, row: int): bool {.optional.}

if listView.setProtocolDelegate(
  listView.xDelegate,
  controller,
  ListViewDelegate,
  ListViewEvents,
):
  listView.reloadData()
```

The erased-delegate path uses event observers registered by receiver-bound protocols installed with `withProto`, or named event implementations installed with `withProtocol`. Direct `connectProtocol(source, observer, SomeEvents)` still works when the observer's concrete slot type is visible at the call site.

## Default Implementations

You can package a reusable protocol implementation and install it later.

```nim
protocol DefaultTextField of TextFieldDelegate:
  method validateText(self: TextController, text: string): bool =
    text.strip.len > 0

  method textDidCommit(self: TextController, text: string) =
    discard

let controller = TextController().withProtocol(DefaultTextField)

doAssert controller.hasAdopted(TextFieldDelegate)
```

For a default protocol attached to a receiver type, use `from` and then construct with `withProto` or `newProto`.

```nim
protocol ControllerInfo from TextController:
  method controllerLabel(self: TextController): string =
    $self.parsed

let controller = TextController().withProto()
doAssert controller.controllerLabel() == "0"
```

## Wrapping Behavior

`pushMethod` adds a reversible wrapper around the current local method. This is useful for temporary overrides, logging, normalization, and tests.

```nim
proc trimBeforeValidation(
  self: DynamicAgent,
  invocation: var Invocation,
  next: DynamicMethod,
) =
  if next.isNil:
    return

  let text = invocation.argsAs(string).strip
  var normalized = initInvocation(invocation.selector, text)

  next(self, normalized)
  if normalized.handled:
    invocation.setResult(normalized.resultAs(bool))

method validateDigitsOnly(self: TextField, text: string): bool {.selector.} =
  text.len > 0 and text.allCharsInSet({'0' .. '9'})

discard field.replaceMethod(validateText, validateDigitsOnly)

let token = field.pushMethod(validateText, trimBeforeValidation)
doAssert field.validateText(" 42 ")
discard token.popMethod()
```

The wrapper receives the previous method as `next`. `popMethod` only restores the stack if the token still points at the current top wrapper.

With `-d:sigilsClosures`, a temporary override that does not need `next` can push a closure method directly.

```nim
let token = field.pushMethod(parseInteger) do(self: TextField, text: string) -> int:
  parseInt(text) + bonus

discard token.popMethod()
```

## Forwarding Hooks

For advanced dynamic behavior, a `DynamicAgent` can resolve or forward unhandled selectors:

- `setResolveMethod` can lazily install a method before dispatch continues.
- `setForwardingTarget` can choose another object for a selector.
- `setForwardInvocation` can handle the final invocation directly.

Prefer a normal method or responder chain first. Use forwarding hooks when the target really is dynamic.

## How They Work

A `Selector[A, R]` is a typed wrapper around a runtime `SigilName`. The `{.selector.}` macro turns an empty method declaration into a selector value plus a direct-send helper. When the method has a body, the macro wraps it as a `DynamicMethod` that unpacks invocation arguments and packs the result. With `-d:sigilsClosures`, closure installs use the same wrapper path, but store the user's closure in the generated `DynamicMethod` environment.

Sending a selector builds an `Invocation` with packed params. Dispatch tries the local method stack, optional lazy resolution, a forwarding target, the next responder, and finally `forwardInvocation`. Required sends raise `UnhandledSelectorError` when nothing handles the invocation. Optional sends return `Option[R]` or a handled `bool`.
