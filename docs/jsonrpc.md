# JSON-RPC adapters

JSON-RPC is opt-in by import. It has no Sigils package feature or compile-time
define:

```nim
import sigils
import sigils/rpcs/jsonrpc
```

The adapter exposes registered Sigils endpoints as JSON-RPC 2.0 methods. A
target and selector, slot, or signal name become `target.name` on the wire.
Protocol registration keeps the protocol's selector allowlist and verifies
conformance before the endpoint is exposed.

```nim
let adapter = newJsonRpcAdapter()
adapter.registerProtocol("calculator", calculator, calculatorProtocol)
adapter.registerSlot("counter", "setValue", counter, Counter.setValue())
adapter.registerSignal("events", source, toSigilName("valueChanged"))
```

Selectors and slots accept JSON-RPC requests or notifications. Registered
signals accept notifications only. Both named object parameters and positional
array parameters are supported. Batches and the standard JSON-RPC errors are
handled by `handleJsonRpc`.

The TCP transports use newline-delimited framing: each request and response is
one compact JSON value followed by `\n`. The default maximum message size is
1 MiB.

## Scheduler bridge

Network I/O and protocol dispatch have separate agents:

- `JsonRpcIoAgent` owns sockets on its I/O scheduler.
- `JsonRpcDispatcher` owns the adapter on the application scheduler.
- `connectJsonRpc` connects requests, responses, and lifecycle events across
  their scheduler boundary.

This separation is important because `DynamicAgent` and registered application
agents stay on their owning application thread. Only the movable I/O agent is
placed on a helper thread.

## Local selector scheduler

Use this topology when the application thread can poll a
`SigilSelectorThread` itself:

```nim
import sigils/threadSelectors
import sigils/rpcs/json/jrSelector

let scheduler = newSigilSelectorThread()
setLocalSigilThread(scheduler)

let dispatcher = newJsonRpcDispatcher(adapter)
let io = newJsonRpcSelectorIo()
dispatcher.connectJsonRpc(io)
emit dispatcher.jsonRpcStartRequested()

while running:
  discard scheduler.poll()

emit dispatcher.jsonRpcStopRequested()
scheduler.closeSelectorThread()
```

`dispatcher.boundAddress` contains the actual listening address after
`dispatcher.isListening` becomes true.

## Selector helper thread

Use a selector helper when the application thread has its own event loop. Poll
the application scheduler so requests can be dispatched and responses returned:

```nim
import sigils/threadSelectors
import sigils/rpcs/json/jrSelector

startLocalThreadDefault()
let
  home = getCurrentSigilThread()
  helper = newSigilSelectorThread()
  dispatcher = newJsonRpcDispatcher(adapter)

block ioLifetime:
  var io = newJsonRpcSelectorIo()
  let proxy = io.moveToThread(helper)
  dispatcher.connectJsonRpc(proxy)
  helper.start()
  emit dispatcher.jsonRpcStartRequested()

  while not dispatcher.isListening:
    discard home.poll()
  # Run the application and continue polling `home`.

  emit dispatcher.jsonRpcStopRequested()
  while dispatcher.isListening:
    discard home.poll()

helper.stop()
helper.join()
helper.closeSelectorThread()
```

## Chronos helper thread

The Chronos transport uses the same bridge and lifecycle. Only the helper and
I/O constructor change:

```nim
import sigils/threadChronos
import sigils/rpcs/json/jrChronos

startLocalThreadDefault()
let
  home = getCurrentSigilThread()
  helper = newSigilChronosThread()
  dispatcher = newJsonRpcDispatcher(adapter)

block ioLifetime:
  var io = newJsonRpcChronosIo()
  let proxy = io.moveToThread(helper)
  dispatcher.connectJsonRpc(proxy)
  helper.start()
  emit dispatcher.jsonRpcStartRequested()

  while not dispatcher.isListening:
    discard home.poll()
  # Run the application and continue polling `home`.

  emit dispatcher.jsonRpcStopRequested()
  while dispatcher.isListening:
    discard home.poll()

helper.stop()
helper.join()
```

Keep the proxy alive until the stop notification has returned to the
application scheduler. As with other Sigils helper-thread actors, release the
proxy before stopping and joining its thread.
