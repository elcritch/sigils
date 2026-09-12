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

LSP uses a different wire format. Import `sigils/rpcs/json/jrFraming` for an
incremental `Content-Length` parser and encoder. Lengths are measured in UTF-8
bytes, headers use `\r\n`, and multiple or fragmented messages are supported:

```nim
import sigils/rpcs/json/jrFraming

var parser = initJsonRpcFrameParser()
parser.add(chunkFromARead)
let payload = parser.nextFrame()
if payload.isSome:
  let response = adapter.handleJsonRpc(payload.get())

let wireMessage = frameJsonRpcMessage(encodedJson)
```

`JsonRpcFrameError` reports missing or duplicate `Content-Length` headers,
oversized messages, and truncated frames. The parser accepts the optional
`Content-Type` header and ignores other extension headers.

LSP method names are not target-prefixed. Register those exact names with the
`*Method` helpers:

```nim
adapter.registerSelectorMethod("initialize", server, initialize)
adapter.registerSelectorMethod("textDocument/hover", server, hover)
```

Use `sendJsonRpcNotification` and `sendJsonRpcRequest` on the dispatcher for
server-to-client LSP messages. Requests keep the caller-supplied JSON-RPC id.
Responses to those requests are emitted as `jsonRpcResponseReceived`; the
dispatcher leaves correlation and timeout policy to the application.

## Scheduler bridge

Network I/O and protocol dispatch have separate agents:

- `JsonRpcIoAgent` owns sockets on its I/O scheduler.
- `JsonRpcDispatcher` owns the adapter on the application scheduler.
- `connectJsonRpc` connects requests, responses, and lifecycle events across
  their scheduler boundary.

This separation is important because `DynamicAgent` and registered application
agents stay on their owning application thread. Only the movable I/O agent is
placed on a helper thread.

## Stdio and LSP

`sigils/rpcs/json/jrStdio` provides a single-connection, synchronous
stdin/stdout transport. It uses the LSP `Content-Length` framing, never closes
the process standard streams, flushes every outgoing message, and reports EOF
through `jsonRpcStopped`:

```nim
import sigils
import sigils/rpcs/jsonrpc
import sigils/rpcs/json/[jrAgents, jrStdio]

startLocalThreadDefault()
let
  home = getCurrentSigilThread()
  adapter = newJsonRpcAdapter()
  dispatcher = newJsonRpcDispatcher(adapter)
  io = newJsonRpcStdioIo()

# Register exact LSP names such as `initialize`, `shutdown`, and
# `textDocument/didOpen` on `adapter` before connecting the transport.
dispatcher.connectJsonRpc(io)
emit dispatcher.jsonRpcStartRequested()

while io.pollJsonRpcStdio():
  # Run any application-thread work queued by handlers before reading again.
  discard home.pollAll(NonBlocking)
```

`pollJsonRpcStdio` blocks for the next complete frame, so it is appropriate for
a command-line server whose handlers finish on the application thread. Use the
incremental framer directly when the host has a nonblocking event loop or needs
to produce unsolicited notifications while stdin is idle. Keep diagnostics and
logging on stderr; stdout is reserved for framed JSON-RPC bytes.

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
