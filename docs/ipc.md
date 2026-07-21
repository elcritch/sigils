# Chronos IPC design

Sigils IPC carries slots, signals, selectors, and runtime protocols across a
Chronos stream. The first transport is deliberately small: CBOR messages inside
a bounded length frame. On POSIX, a Chronos `AddressFamily.Unix` endpoint is a
Unix-domain socket. On Windows, Chronos maps that same address family to a named
pipe. Enable both the `chronos` and `ipc` package features to use this layer.

## Wire model

Each connection is bidirectional. One peer may issue requests while also
serving requests from the other peer.

The RPC envelope is CBOR with these fields:

- protocol version;
- message kind (`request`, `response`, `notify`, or `error`);
- request ID for request/response correlation;
- target and method/signal name;
- nested CBOR payload;
- error code and message.

Selectors and slots use request/response. Signals use one-way notifications.
Registering a `SigilProtocol` exposes only the selectors declared by that
protocol and checks that the receiver conforms before the server starts.

The native stream frame is:

```text
+-------------+--------------------------+------------------------+
| CBOR tag 24 | fixed byte-string head   | CBOR envelope          |
| d8 18       | 5a + u32 byte length     | exactly byte length    |
+-------------+--------------------------+------------------------+
```

Sigils applies a fixed32 application profile to the standard encoded-CBOR tag.
The tag and byte-string head form a seven-byte prefix; see the
[tag-24 framing profile](cbor-tag24-fixed32-frame.md). The default maximum
payload is 16 MiB. The reader rejects the wrong prefix, zero-length payloads,
and oversized frames before allocating their payload. The writer submits the
tag, byte-string header, and payload to Chronos in one write, so concurrent RPC
calls cannot interleave parts of different frames.

IPC CBOR is attached only to calls that cross the IPC boundary. Normal local and
cross-thread Sigils calls continue using the existing variant representation;
this avoids serialization work and preserves support for process-local values
such as closures and agent references.

## API outline

- `newIpcRouter()` creates an endpoint registry.
- `registerSlot` exposes a generated slot.
- `registerSignal` and `registerSignalProtocol` allow incoming notifications.
- `registerSelector` exposes one typed selector.
- `registerProtocol` exposes a conforming protocol's selector surface.
- `createIpcServer` binds a Chronos TCP, Unix-socket, or named-pipe endpoint.
- `connectIpc` creates a bidirectional peer.
- `callSlot`, `callSelector`, and `notifySignal` are the typed client operations.

Server handlers currently run synchronously on their Chronos dispatcher. Keep
them short and nonblocking, or hand work to a Sigils worker thread. Transport
security is also the caller's responsibility: protect local socket/pipe paths,
and do not expose the direct TCP transport to untrusted networks without an
authentication and encryption layer.
