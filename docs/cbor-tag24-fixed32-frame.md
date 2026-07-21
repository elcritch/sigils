# Tag-24 Fixed32 Stream Framing Application Profile

Status: Working Draft 0.2, 2026-07-21

## Abstract

This document defines an application profile of CBOR tag 24 for carrying one
encoded CBOR data item over a byte stream. The tag content is a definite-length
byte string whose length is always serialized as an unsigned 32-bit value. The
tag and byte-string head form a fixed seven-byte prefix, allowing a receiver to
validate the frame and determine its payload length before allocating or
processing the payload.

This profile does not define a new CBOR tag or request an IANA assignment.

## 1. Introduction

CBOR data items are self-delimiting, but determining the end of an arbitrary
item requires a CBOR parser that can incrementally traverse every nested value.
Some byte-stream applications instead need to read a small fixed header, check
a payload limit, and then read or forward the encoded item as opaque bytes.

CBOR tag 24 identifies a byte string containing one encoded CBOR data item. The
CBOR data model does not constrain the serialization width of the byte-string
length, so a general tag-24 decoder must inspect the byte-string head before it
knows how many length bytes follow. This application profile always uses a
32-bit byte-string length. A stream receiver can therefore read and validate a
fixed seven-byte prefix before allocating or processing the payload, without
recursively parsing the enclosed item to discover its boundary.

Because the length is encoded in the tagged CBOR byte-string head rather than
as an out-of-band transport prefix, each complete frame remains valid CBOR and
concatenated frames remain a valid CBOR Sequence.

This profile defines framing only. It does not assign application semantics to
the enclosed CBOR item.

## 2. Requirements language

The key words **MUST**, **MUST NOT**, **REQUIRED**, **SHALL**, **SHALL NOT**,
**SHOULD**, **SHOULD NOT**, **RECOMMENDED**, **NOT RECOMMENDED**, **MAY**, and
**OPTIONAL** in this document are to be interpreted as described in BCP 14
([RFC 2119](https://www.rfc-editor.org/rfc/rfc2119.html) and
[RFC 8174](https://www.rfc-editor.org/rfc/rfc8174.html)) when, and only when,
they appear in all capitals, as shown here.

## 3. Terminology

- **Frame:** Tag 24, its byte-string content, and the encoded CBOR payload
  carried by that byte string.
- **Frame prefix:** The first seven bytes of a frame.
- **Frame length:** The unsigned 32-bit byte count in the frame prefix.
- **Payload:** The bytes following the frame prefix. These bytes encode one
  CBOR data item.
- **Application limit:** A maximum payload size selected by an implementation
  or application and normally much smaller than `2^32 - 1`.

All multi-byte integers use network byte order, most significant byte first.

## 4. Profile definition

This profile uses CBOR tag 24, "Encoded CBOR data item," whose content is a byte
string containing exactly one encoded CBOR data item.

The data-model relationship can be described in CDDL as:

```cddl
fixed32-stream-frame = #6.24(bytes .cbor framed-item)
framed-item = any
```

CDDL describes the tag content but does not express the required serialization
width. The byte-level requirements in Section 5 are normative.

## 5. Wire representation

Every frame MUST begin with this seven-byte prefix:

```text
+----------+------------------+------------------------+
| d8 18    | 5a NN NN NN NN  | N payload bytes        |
| tag 24   | byte string + N  | encoded CBOR data item |
+----------+------------------+------------------------+
```

Equivalently:

```text
d8 18 5a NN NN NN NN <N payload bytes>
```

| Offset | Size | Meaning |
|---:|---:|---|
| 0 | 2 | CBOR tag 24 in its preferred encoding (`d8 18`) |
| 2 | 1 | Definite byte string with a 32-bit length argument (`5a`) |
| 3 | 4 | Payload length `N`, unsigned and big endian |
| 7 | `N` | Encoded CBOR payload |

The following requirements apply:

1. Tag 24 MUST use its two-byte preferred encoding `d8 18`.
2. The tag content MUST be a definite-length CBOR byte string.
3. The byte-string head MUST be `5a` followed by a four-byte length, even when
   that length could be represented using a shorter CBOR argument.
4. The length `N` MUST be at least one and no greater than `2^32 - 1`.
5. Exactly `N` payload bytes MUST follow the prefix.
6. The payload MUST encode exactly one well-formed CBOR data item. An empty
   payload, malformed item, truncated item, or multiple concatenated items is
   invalid.
7. An implementation MUST apply its application limit before allocating or
   reading an `N`-byte payload.

For payloads shorter than 65536 bytes, the required `5a` byte-string head is a
valid but non-preferred CBOR serialization. Consequently, such outer frames do
not satisfy the core deterministic encoding requirements in
[RFC 8949 Section 4.2.1](https://www.rfc-editor.org/rfc/rfc8949.html#section-4.2.1).
The enclosed payload MAY independently use a deterministic CBOR encoding.

## 6. Encoder behavior

An encoder MUST:

1. Encode or receive exactly one CBOR payload item.
2. Determine the encoded payload length before writing the frame prefix.
3. Reject an empty payload, a payload larger than `2^32 - 1`, or a payload
   larger than its application limit.
4. Write `d8 18 5a`.
5. Write the payload length as an unsigned 32-bit big-endian integer.
6. Write exactly that many payload bytes.

An encoder SHOULD submit a complete frame to a serialized stream writer so
that concurrent producers cannot interleave frame bytes.

## 7. Decoder behavior

A byte-stream decoder can process a frame as follows:

1. Read exactly seven bytes.
2. Verify that bytes 0 through 2 are `d8 18 5a`.
3. Decode bytes 3 through 6 as the unsigned 32-bit payload length `N`.
4. Reject `N = 0` or `N` greater than the application limit.
5. Read exactly `N` payload bytes.
6. Verify, either immediately or at the application boundary, that the payload
   encodes exactly one well-formed CBOR item.

If the prefix, length, or payload is invalid, the decoder MUST report a framing
error. This profile defines no resynchronization marker. A connection-oriented
transport SHOULD close the affected connection unless its containing protocol
defines a safe recovery mechanism.

A generic CBOR decoder can decode the complete frame according to the standard
tag-24 semantics. A decoder configured to require RFC 8949 core deterministic
encoding can reject the forced 32-bit byte-string length for shorter payloads.

## 8. Concatenation and stream use

Frames MAY be concatenated without separators. The result is a CBOR Sequence
as defined by [RFC 8742](https://www.rfc-editor.org/rfc/rfc8742.html), where
each sequence element is one tag-24 frame.

The frame length applies only to the byte string in its own frame. It does not
include the seven-byte prefix or any subsequent frame. There is no end-of-stream
marker; the containing transport defines connection or stream closure.

## 9. Examples and test vectors

### 9.1 One-byte unsigned integer

The payload `00` is the CBOR unsigned integer zero:

```text
d8 18 5a 00 00 00 01 00
```

### 9.2 One-byte empty map

The payload `a0` is an empty CBOR map:

```text
d8 18 5a 00 00 00 01 a0
```

### 9.3 Four-byte payload

The payload `83 01 02 03` is the CBOR array `[1, 2, 3]`:

```text
d8 18 5a 00 00 00 04 83 01 02 03
```

### 9.4 Invalid encodings

| Encoding | Reason |
|---|---|
| `d8 18 5a 00 00 00 00` | Empty payload cannot contain a CBOR item |
| `d8 18 41 00` | Byte-string length does not use the required 32-bit form |
| `d8 18 5a 00 00 00 02 00` | Payload is truncated |
| `d8 18 5a 00 00 00 02 00 00` | Payload contains two CBOR items |
| `d8 18 5a 00 00 00 01 ff` | Payload is not a well-formed CBOR item |

## 10. Design considerations

### 10.1 Why tag 24

Tag 24 already defines the required data model: a byte string containing one
encoded CBOR data item. Using it avoids allocating a new global tag for a
serialization convention. The containing application protocol identifies the
fixed32 requirement; tag 24 alone does not advertise this profile.

### 10.2 Why a byte string

A tagged byte string makes the complete frame one valid CBOR item and uses the
existing byte-string length argument as the transport length. A separate
integer followed by raw bytes would instead be a CBOR Sequence and would not be
entirely enclosed by the tag.

### 10.3 Why a fixed 32-bit length

A 32-bit length supports payloads up to `2^32 - 1` bytes while allowing the
receiver to fetch the complete prefix with one fixed-size read. Applications
are expected to impose substantially smaller limits.

## 11. Security considerations

The length field is controlled by the sender and MUST be treated as untrusted.
Decoders MUST reject lengths above an application limit before allocating
memory. Implementations SHOULD use checked integer conversions when converting
the unsigned 32-bit length to a platform-dependent size type.

The payload is also untrusted CBOR input. Payload decoders SHOULD enforce limits
on nesting depth, collection size, string size, and total processing work.
Valid framing does not imply that the enclosed item is valid for an application
protocol.

This framing provides no confidentiality, integrity, authentication, replay
protection, or peer authorization. Applications requiring those properties
must provide them in the containing protocol or transport.

A malformed frame can make the boundary of subsequent data unreliable. Unless
a containing protocol defines resynchronization, implementations SHOULD stop
processing that stream after a framing error.

## 12. References

- [RFC 2119: Key words for use in RFCs to Indicate Requirement Levels](https://www.rfc-editor.org/rfc/rfc2119.html)
- [RFC 8174: Ambiguity of Uppercase vs Lowercase in RFC 2119 Key Words](https://www.rfc-editor.org/rfc/rfc8174.html)
- [RFC 8742: Concise Binary Object Representation (CBOR) Sequences](https://www.rfc-editor.org/rfc/rfc8742.html)
- [RFC 8949: Concise Binary Object Representation (CBOR)](https://www.rfc-editor.org/rfc/rfc8949.html)
- [IANA CBOR Tags Registry](https://www.iana.org/assignments/cbor-tags/cbor-tags.xhtml)
