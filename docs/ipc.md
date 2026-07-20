# Chronos IPC design

Sigils IPC carries slots, signals, selectors, and runtime protocols across a
Chronos stream. The first transport is deliberately small: CBOR messages inside
a bounded length frame. On POSIX, a Chronos `AddressFamily.Unix` endpoint is a
Unix-domain socket. On Windows, Chronos maps that same address family to a named
pipe.

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
+-----------------------+----------------------------+
| payload length (u32)  | CBOR envelope              |
| big endian, 4 bytes   | exactly payload length     |
+-----------------------+----------------------------+
```

The default maximum payload is 16 MiB. The reader rejects zero-length and
oversized frames before allocating their payload. The writer submits the header
and payload to Chronos in one write, so concurrent RPC calls cannot interleave
parts of different frames.

IPC CBOR is attached only to calls that cross the IPC boundary. Normal local and
cross-thread Sigils calls continue using the existing variant representation;
this avoids serialization work and preserves support for process-local values
such as closures and agent references.

## WebSocket versus CoAP

| Choice | Strength | Cost for local IPC | Decision |
| --- | --- | --- | --- |
| Bounded length frame | Four bytes of framing, direct fit for reliable byte streams, and one bounded allocation | No browser interoperability or built-in ping/pong | Use for Unix sockets, Windows named pipes, and direct TCP |
| WebSocket | Browser support, binary message boundaries, established ping/pong and close behavior | HTTP upgrade, client masking, fragmentation, control frames, and extra state that local pipes do not need | Add later as a gateway transport, keeping the same CBOR RPC envelope |
| CoAP | Compact resource-oriented protocol, UDP multicast/discovery, optional datagram reliability | Its message IDs, tokens, retransmission, deduplication, and URI/options model overlap with the RPC envelope; CoAP over streams uses a different format | Use only for a dedicated constrained-device/UDP adapter, not native IPC framing |

WebSocket is a good browser edge, but it is more than a frame header. RFC 6455
requires the HTTP opening handshake and defines masking, fragmentation, control
frames, and a closing handshake. Chronos itself provides HTTP and stream
transports but does not include a WebSocket module. The separate
[`nim-websock`](https://github.com/status-im/nim-websock) project is built on
Chronos and provides both client and server support. Mummy also provides
WebSockets, but its implementation is part of Mummy's own threaded HTTP server,
not a Chronos stream adapter.

The partial CoAP branch in `fastrpc` parses the RFC 7252 datagram header, token,
options, and payload. It does not yet provide a complete encoder,
confirmable-message retransmission, deduplication, Observe/blockwise behavior,
or the RFC 8323 stream format. Nesting that header inside a reliable local
stream would duplicate correlation and reliability machinery without providing
CoAP's main benefits.

References:

- [RFC 6455: The WebSocket Protocol](https://www.rfc-editor.org/info/rfc6455/)
- [RFC 7252: The Constrained Application Protocol](https://www.rfc-editor.org/info/rfc7252/)
- [RFC 8323: CoAP over TCP, TLS, and WebSockets](https://www.rfc-editor.org/info/rfc8323/)

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
