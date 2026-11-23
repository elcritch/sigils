# Signals and slots

Signals announce events. Slots are procedures connected to those signals.
An emission delivers the signal's arguments to each connected slot.

## Connect and emit

Declare a signal with `{.signal.}` and a receiving procedure with `{.slot.}`.
The first parameter identifies the source or receiver. The remaining slot
parameters must match the signal's payload.

```nim
import sigils

type Counter = ref object of Agent
  value: int

proc valueChanged(source: Counter, value: int) {.signal.}

proc setValue(self: Counter, value: int) {.slot.} =
  self.value = value

let source = Counter()
let display = Counter()
connect(source, valueChanged, display, setValue)

emit source.valueChanged(42)
doAssert display.value == 42

disconnect(source, valueChanged, display, setValue)
emit source.valueChanged(7)
doAssert display.value == 42
```

Agents can send or receive signals. A signal can connect to multiple slots,
including slots on different receivers. Calling `connect` repeatedly for the
same connection is idempotent. A slot is also an ordinary Nim procedure, so
`display.setValue(10)` calls it directly.

When overload resolution needs the receiver type, use the generated slot
descriptor, such as `Counter.setValue`, in the `connect` call.

## Ignoring a payload

A slot with no payload can subscribe to a signal with arguments when the
connection explicitly permits it.

```nim
proc refresh(self: Counter) {.slot.} =
  echo "refresh"

connect(source, valueChanged, display, refresh, acceptVoidSlot = true)
```

## Delivery and lifetime

Ordinary local connections call their slots during `emit`. A queued connection
runs when its scheduler processes the message. Queued calls do not keep the
receiver alive, so keep it alive until delivery is complete. See the
[threading guide](threading.md) for queued and cross-thread delivery, actor
ownership, and scheduler polling.

To connect a closure instead of a named slot, enable `-d:sigilsClosures`
(or the `closures` package feature) and import `sigils/closures`. See the
[closure example in the README](https://github.com/elcritch/sigils/blob/main/README.md#closures)
for its setup and lifetime considerations.

For a named operation that needs a reply, use a [selector](selectors.md).
For observing individual entries in a keyed collection, see
[collection Sigils](collection-sigils.md).
