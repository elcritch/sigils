# Higher order messaging with Sigils protocols and Merenda views

An inspector wants the accessibility labels of a window's child views. It knows the children as `View` objects. A plain view can answer with its identifier, a button can answer with its title, and a custom control can install its own implementation. The inspector should be able to make one request and keep the replies in child order. This is a good first use of [higher order messaging](objc-collection-metaprogramming.md) in NimKit.

The prototype below uses Sigils' typed selectors. A protocol supplies the message, an ordinary Nim proc decides how to distribute it, and each receiver decides how to answer. Sigils now provides `collectLocal`, `selectLocal`, and `collectEachLocal` in `sigils/hom`. The `collectSend` macro and generated overload shown here are exploratory examples. See [Sending to Collections](selectors.md#sending-to-collections) for the implemented API.

## Where the AppKit analogy holds

| Merenda behavior | How NimKit implements it | Consequence for HOM |
| --- | --- | --- |
| Views and controls respond to messages | `Responder` inherits from Sigils' `DynamicAgent`. `View` inherits from `Responder`, and `Button` inherits through `Control`. View initialization installs `DefaultAccessibilityProtocol`. Button initialization layers button-specific behavior over it. | The inspector can ask every child for its label. A button can answer with its title even when the caller only knows it as a view. [View initialization][views] · [Button accessibility][buttons] |
| Commands travel up a responder chain | Merenda links responders and uses a local send at each hop for policies such as key equivalents. The first responder returning true can consume the event. | A bulk query about individual children should use local sends. Otherwise several children can all report an answer from the same ancestor. [Responder routing][responders] |
| Delegates and data sources have optional methods | The table asks its data source for a typed cell value, then falls back to text. It also validates row/column membership and formats typed values for display. | Distributing `textForCell` alone would bypass behavior callers expect from `tableCellText`. A bulk export of visible text should reuse the latter. [Table lookup and fallback][table] |
| Models and widgets have different representations | `ArrayController` arranges plain `ModelItem` values with stable identifiers, typed fields, and a filter proc. A row may carry a separate `representedObject: DynamicAgent`. | Apply a selector to a view, data source, or represented object. A title or field query on a plain row can use its existing value API. [Model items and controllers][models] |

Merenda's foundation module already re-exports Sigils selectors and defines shared payloads such as `ActionArgs`. There is no need for a second message registry. A `protocol` declaration produces callable selector values such as `accessibilityLabel()` of type `Selector[tuple[], string]`. Its `SigilProtocol` descriptor records requirements, signal names, and slots. That descriptor is useful for inspection and adoption. The selector value carries the argument and result types needed for a bulk call. [NimKit selector definitions][foundation] · [Sigils protocols and generated selectors](selectors.md#protocols)

## Two operations on real controls

These fragments can be read as one Nim module, in order. The only primitive the collection needs is `performLocal(selector, args, value)`. It returns a handled flag and writes the answer into typed storage. The helper keeps those facts separate using the same `Opt` type that Sigils uses for keyed item projections. This matters for a selector such as `accessibilityParent()`: a root view legitimately answers with a nil `View`. That is a different answer from a receiver missing the selector. [Selector dispatch](../sigils/selectors.nim) · [Keyed projections](collection-sigils.md) · [NimKit accessibility protocol][accessibility]

```nim
import std/macros
import results
import sigils/selectors
import merenda/nimkit/view/views
import merenda/nimkit/controls/buttons
import merenda/nimkit/accessibility/accessibilityprotocols

proc queryLocal[A, R](
    receiver: DynamicAgent, message: Selector[A, R], args: A
): Opt[R] =
  var value: R
  if receiver.performLocal(message, args, value):
    Opt.some(value)
  else:
    Opt.none(R)

proc collectLocal[T: DynamicAgent; A, R](
    receivers: openArray[T], message: Selector[A, R], args: A
): seq[Opt[R]] =
  let members = @receivers
  for receiver in members:
    result.add receiver.queryLocal(message, args)

proc selectLocal[T: DynamicAgent; A](
    receivers: openArray[T], predicate: Selector[A, bool], args: A
): seq[T] =
  let members = @receivers
  for receiver in members:
    if receiver.trySendLocal(predicate, args).get(false):
      result.add receiver
```

```nim
let
  root = newView()
  group = newView("group")
  save = newButton("Save")
root.addSubview(group)
root.addSubview(save)

let children = root.subviews()
doAssert children.collectLocal(accessibilityLabel(), ()) ==
  @[Opt.some("group"), Opt.some("Save")]
doAssert children.selectLocal(isAccessibilityElement(), ()) == @[View(save)]
```

`collectLocal` preserves a position for every input, including a nil receiver or an unhandled send. `selectLocal` preserves the original receiver type and keeps only receivers that answer true. A caller interested in the distinction between false and unhandled can collect the same predicate and inspect the replies. All methods on NimKit's accessibility protocol are optional. Checking whether the receiver has adopted the protocol cannot establish whether it answers this particular message. Sending once also preserves lazy resolution and local forwarding hooks. [Accessibility declarations][accessibility] · [Sigils optional sends](selectors.md#optional-sends)

The `@receivers` copy fixes membership and order before the first call and keeps the objects alive for the traversal. A handler may remove a sibling or insert another child. This pass still visits the original members, and each sees its current state at dispatch time. Calls run synchronously on the owning UI thread. An exception propagates at the failing element, so any earlier side effects have already occurred. The snapshot costs O(n) references in addition to the output. I would start with inspector queries, where this contract is easy to explain, before considering allocation overhead in rendering or hit testing.

## Capturing the next message in Nim

An Objective-C HOM proxy captures the next message through forwarding. Sigils has a `setForwardInvocation` hook too, but a direct `accessibilityLabel` send already promises its caller a `string`. A proxy returning a sequence through that call would violate the typed result contract. Sigils' local invocation can borrow caller-owned argument and result storage for the duration of a synchronous send. Each element should get a fresh typed send. [Invocation and result handling](../sigils/selectors.nim) · [Local argument ownership](selector-payload-review.md)

Nim can capture the expression one step earlier. The small macro below turns `children.collectSend(accessibilityLabel())` into `collectLocal(children, accessibilityLabel(), ())`. The selector's type determines the element result, and the outer operation determines the collection result. One call site can therefore infer `seq[Opt[string]]` and another `seq[Opt[bool]]`.

```nim
macro collectSend(receivers: typed, message: untyped): untyped =
  message.expectKind(nnkCall)
  let selectorValue = newCall(message[0])
  var args = newTree(nnkTupleConstr)
  if message.len == 2:
    args = message[1]
  else:
    for index in 1 ..< message.len:
      args.add message[index]
  newCall(bindSym"collectLocal", receivers, selectorValue, args)

doAssert children.collectSend(accessibilityLabel()) ==
  @[Opt.some("group"), Opt.some("Save")]
```

This sketch accepts ordinary positional calls to declared selectors. For zero parameters it builds `()`, for one it passes the value directly, and for several it builds a tuple in declaration order. The receiver expression and each argument expression are evaluated once before traversal. The compiler still checks the packed argument type, and `selectLocal` only accepts a predicate returning `bool`. If this syntax becomes public, I would share the argument-packing rules with Sigils' selector generator and test named/default arguments and module-qualified selectors before promising those forms. [Selector argument generation](../sigils/selectors.nim)

There is also a way to get almost the original `[[views collect] label]` spelling. Give the intermediate receiver a Nim type. This overload was enough to make a two-stage send work on the same views.

```nim
type Collecting[T] = object
  members: seq[T]

proc collecting[T: DynamicAgent](members: seq[T]): Collecting[T] =
  Collecting[T](members: members)

proc accessibilityLabel[T: DynamicAgent](batch: Collecting[T]): seq[Opt[string]] =
  batch.members.collectLocal(accessibilityprotocols.accessibilityLabel(), ())

doAssert children.collecting().accessibilityLabel() ==
  @[Opt.some("group"), Opt.some("Save")]
```

Here the compiler chooses the overload from the type of `collecting()`. Sigils chooses the label implementation separately on each element. A protocol macro could emit one such overload per declared query and a selection overload for Boolean results. That would give editors real method names and signatures to complete. I would generate them only for protocols that request the syntax. The ordinary procs already accept selectors chosen at runtime, and the call macro covers many protocols with one implementation. Generating an overload for every method is worth measuring against those simpler forms.

## Varying the argument as well as the receiver

Suppose an inspector is applying a pair of edited labels, one per selected view. Repeating one selector with two different arguments is the case that made MPWFoundation's `each` interesting. For UI edits I would check lengths up front. The historical library stopped at the shorter input. A truncated edit would leave some views carrying stale labels. [Higher Order Messaging, §4.1](https://scg.unibe.ch/archive/papers/Weih05aHigherOrderMessagingOOPSLA2005.pdf)

```nim
proc collectEachLocal[T: DynamicAgent; A, R](
    receivers: openArray[T], message: Selector[A, R], args: openArray[A]
): seq[Opt[R]] =
  if receivers.len != args.len:
    raise newException(ValueError, "one argument per receiver required")
  let
    members = @receivers
    arguments = @args
  for i, receiver in members:
    result.add receiver.queryLocal(message, arguments[i])

let edits = children.collectEachLocal(setAccessibilityLabel(), ["Section", "Submit"])
doAssert edits[0].isSome and edits[1].isSome
doAssert children.collectSend(accessibilityLabel()) ==
  @[Opt.some("Section"), Opt.some("Submit")]
```

Sigils represents a selector without a return value using the empty tuple, so the editor can still see which setters were handled. A purpose-built command API could return just the handled flags. Signals and slots serve another purpose here. A setter can emit its normal change event, and observers can connect using the existing protocol machinery. Replacing the send with a broadcast would lose per-receiver replies. [Selectors and protocol events](selectors.md#protocols)

## Recursion and composition

The collection operations send to the receivers supplied by the caller. The original HOM paper also describes composing messages, for example selecting employees by applying a predicate to the result of their `name` message. In Sigils, `findFirst(accessibilityLabel(), (), predicate)` supports that query pattern for one match. F-Script's recursive patterns additionally apply messages at a chosen depth in nested arrays and preserve the array structure. [Higher Order Messaging, §4.1](https://scg.unibe.ch/archive/papers/Weih05aHigherOrderMessagingOOPSLA2005.pdf) · [OOPAL, §5.3](https://scg.unibe.ch/archive/papers/Moug03aOOPALOOPSLA.pdf)

In a view tree, the caller chooses the edge to follow. `root.subviews()` gives the immediate children. NimKit's accessibility traversal visits accessible descendants and orders them for inspection, so the same selector query can search the whole subtree.

```nim
import sigils/hom

let saveButton = root.orderedAccessibilityElements().findFirst(
  accessibilityLabel(), (), proc(label: string): bool = label == "Save")
```

This stops querying labels at the first match. NimKit builds the full list of accessible descendants first. To stop both querying and descending at the first match, pass the child relation to the tree overload of `findFirst`.

```nim
let firstSaveView = root.findFirst(
  proc(view: View): seq[View] = view.subviews(),
  accessibilityLabel(), (),
  proc(label: string): bool = label == "Save")
```

The tree overload starts at the root and follows `subviews` in view order. It can match any view in that tree. A caller can supply `accessibilityChildren` as the child relation and use an element predicate to apply any additional accessibility rules it needs. [NimKit accessibility traversal][traversal]

The same traversal can supply receivers to collection operations. For example, the inspector can select views by their accessibility predicate as it walks the tree:

```nim
let accessibleViews = root.depthFirst(
  proc(view: View): seq[View] = view.subviews()
).selectLocal(isAccessibilityElement(), ())
```

## Where observation would fit

A one-shot bulk query and a live inspector column have different lifetimes. Sigils' `CollectionSigil[K, T]` can track membership/order and observe an item by stable key. A selector may also read plain widget fields. Updating a button title in place does not publish a new collection snapshot. A live query would need an event or tracked read covering each input to the selector, plus subscription teardown when a key disappears. For example, the default accessibility label setter writes a field, while the default accessibility value setter explicitly emits a notification. An inspector must establish which changes it can observe before it caches answers. [Keyed collection behavior](collection-sigils.md) · [NimKit accessibility setters][accessibility-setters]

Merenda at the revision studied also has its own `app/collectionsigils.nim`, whose item projection uses `std/options.Option`. Sigils' current `sigils/collections.nim` uses `results.Opt`. The bulk operations above depend only on the receiver sequence and the selector, so either collection can supply a snapshot of agent references. For plain `ModelItem` rows, a controller can keep the row identifier alongside any reply from its represented object. That preserves identity through filtering and reordering. [Merenda collection implementation][merenda-collections] · [Sigils collection implementation](../sigils/collections.nim)

The typed collection procs live in the opt-in `sigils/hom` module. Widget-specific traversal, event subscriptions, and table fallbacks belong in NimKit. The first Merenda caller I would try is its existing `ViewInspector`. It already displays the selected view's accessibility label and role. To add an accessibility outline, the inspector could pass the result of NimKit's `orderedAccessibilityElements` to a label or role query. That traversal already accounts for ignored views and accessible descendants. A key-equivalent dispatch should keep its current stop-on-first-consumer rule. [Current inspector details][inspector] · [Accessibility traversal][traversal] · [Responder routing][responders]

The prototype ran headlessly on Nim 2.2.12 against Merenda `d5680a0`, with both its Atlas-pinned Sigils `5190b38` and this checkout's selector code. The checks covered button overrides, local versus responder-chain lookup, a handled nil parent, false versus missing predicates, reentrant changes to membership, and rejection of unequal argument counts before delivery. The call macro was exercised with zero, one, and two positional arguments. Timing and live subscriptions remain open design questions.

[views]: https://github.com/elcritch/merenda/blob/d5680a018181f2af56615611c53ba7927d29ed10/src/merenda/nimkit/view/views.nim#L479
[buttons]: https://github.com/elcritch/merenda/blob/d5680a018181f2af56615611c53ba7927d29ed10/src/merenda/nimkit/controls/buttons.nim#L385
[responders]: https://github.com/elcritch/merenda/blob/d5680a018181f2af56615611c53ba7927d29ed10/src/merenda/nimkit/responder/responders.nim#L132
[table]: https://github.com/elcritch/merenda/blob/d5680a018181f2af56615611c53ba7927d29ed10/src/merenda/nimkit/tables/tablecore.nim#L942
[models]: https://github.com/elcritch/merenda/blob/d5680a018181f2af56615611c53ba7927d29ed10/src/merenda/nimkit/app/modelcontrollers.nim#L40
[foundation]: https://github.com/elcritch/merenda/blob/d5680a018181f2af56615611c53ba7927d29ed10/src/merenda/nimkit/foundation/selectors.nim
[accessibility]: https://github.com/elcritch/merenda/blob/d5680a018181f2af56615611c53ba7927d29ed10/src/merenda/nimkit/accessibility/accessibilityprotocols.nim#L186
[accessibility-setters]: https://github.com/elcritch/merenda/blob/d5680a018181f2af56615611c53ba7927d29ed10/src/merenda/nimkit/accessibility/accessibilityprotocols.nim#L268
[traversal]: https://github.com/elcritch/merenda/blob/d5680a018181f2af56615611c53ba7927d29ed10/src/merenda/nimkit/accessibility/accessibilityprotocols.nim
[merenda-collections]: https://github.com/elcritch/merenda/blob/d5680a018181f2af56615611c53ba7927d29ed10/src/merenda/nimkit/app/collectionsigils.nim
[inspector]: https://github.com/elcritch/merenda/blob/d5680a018181f2af56615611c53ba7927d29ed10/src/merenda/nimkit/debug/viewinspectors.nim#L207
