# CBF4: Fixed32-Framed Encoded CBOR Data Item

Status: Working Draft 0.1, 2026-07-21

The CBOR tag number in this document is proposed and has not been assigned by
IANA. Implementations must not assume that tag 52212 is available for
interoperable use until the assignment is confirmed.

## Abstract

This document defines a CBOR tag for carrying one encoded CBOR data item in a
definite-length byte string whose length is always serialized as an unsigned
32-bit value. The tag and byte-string head form a fixed eight-byte prefix,
allowing a byte-stream receiver to determine and validate the payload length
without incrementally parsing the enclosed CBOR item.

The proposed tag number is 52212 (`0xCBF4`). Its content is a CBOR byte string.
The bytes in that string encode exactly one well-formed CBOR data item.

## 1. Introduction

CBOR data items are self-delimiting, but determining the end of an arbitrary
item requires a CBOR parser that can incrementally traverse every nested value.
Some byte-stream applications instead need to read a small fixed header, check
a payload limit, and then read or forward the encoded item as opaque bytes.

CBOR tag 24 identifies a byte string containing one encoded CBOR data item, but
it permits the byte-string length to use any valid CBOR argument width. This
document defines a distinct serialization profile that always uses a 32-bit
byte-string length. The result is a fixed eight-byte frame prefix while the
entire frame remains one well-formed CBOR data item. A stream receiver can read
and validate this fixed prefix before allocating or processing the payload,
without recursively parsing the enclosed item to discover its boundary.
Because the length is encoded in the tagged CBOR byte-string head rather than
as an out-of-band transport prefix, each complete frame remains valid CBOR and
concatenated frames remain a valid CBOR Sequence.

This tag defines framing only. It does not assign application semantics to the
enclosed CBOR item.

## 2. Requirements language

The key words **MUST**, **MUST NOT**, **REQUIRED**, **SHALL**, **SHALL NOT**,
**SHOULD**, **SHOULD NOT**, **RECOMMENDED**, **NOT RECOMMENDED**, **MAY**, and
**OPTIONAL** in this document are to be interpreted as described in BCP 14
([RFC 2119](https://www.rfc-editor.org/rfc/rfc2119.html) and
[RFC 8174](https://www.rfc-editor.org/rfc/rfc8174.html)) when, and only when,
they appear in all capitals, as shown here.

## 3. Terminology

- **Frame:** The proposed tag, its byte-string content, and the encoded CBOR
  payload carried by that byte string.
- **Frame prefix:** The first eight bytes of a frame.
- **Frame length:** The unsigned 32-bit byte count in the frame prefix.
- **Payload:** The bytes following the frame prefix. These bytes encode one
  CBOR data item.
- **Application limit:** A maximum payload size selected by an implementation
  or application and normally much smaller than `2^32 - 1`.

All multi-byte integers in this document use network byte order, most
significant byte first.

## 4. Tag definition

The proposed registration is:

| Field | Value |
|---|---|
| Tag number | 52212 (`0xCBF4`) |
| Name | Fixed32-Framed Encoded CBOR Data Item |
| Data item | Byte string |
| Semantics | A fixed-32-bit-length byte string containing exactly one encoded CBOR data item |

The data-model relationship can be described in CDDL as:

```cddl
fixed32-framed-cbor = #6.52212(bytes .cbor framed-item)
framed-item = any
```

CDDL describes the tag content but does not express the required serialization
width. The byte-level requirements in Section 5 are normative.

## 5. Wire representation

Every frame MUST begin with this eight-byte prefix:

```text
0               1               2               3
0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+---------------+-------------------------------+---------------+
|     0xd9      |            0xcbf4             |     0x5a      |
+---------------+-------------------------------+---------------+
|                    payload length (uint32)                     |
+---------------------------------------------------------------+
|                     payload (length bytes)                    ...
+---------------------------------------------------------------+
```

Equivalently:

```text
d9 cb f4 5a NN NN NN NN <N payload bytes>
```

| Offset | Size | Meaning |
|---:|---:|---|
| 0 | 1 | CBOR tag with a 16-bit tag argument (`0xd9`) |
| 1 | 2 | Proposed tag number 52212 (`0xcbf4`) |
| 3 | 1 | Definite byte string with a 32-bit length argument (`0x5a`) |
| 4 | 4 | Payload length `N`, unsigned and big endian |
| 8 | `N` | Encoded CBOR payload |

The following requirements apply:

1. The tag MUST use the three-byte preferred encoding `d9 cb f4`.
2. The tag content MUST be a definite-length CBOR byte string.
3. The byte-string head MUST be `0x5a` followed by a four-byte length, even
   when that length could be represented using a shorter CBOR argument.
4. The length `N` MUST be at least one and no greater than `2^32 - 1`.
5. Exactly `N` payload bytes MUST follow the prefix.
6. The payload MUST encode exactly one well-formed CBOR data item. An empty
   payload, malformed item, truncated item, or multiple concatenated items is
   invalid.
7. An implementation MUST apply its application limit before allocating or
   reading an `N`-byte payload.

For payloads shorter than 65536 bytes, the required `0x5a` byte-string head is
a valid but non-preferred CBOR serialization. Consequently, the outer frame
does not satisfy the core deterministic encoding requirements in
[RFC 8949 Section 4.2.1](https://www.rfc-editor.org/rfc/rfc8949.html#section-4.2.1).
The enclosed payload MAY independently use a deterministic CBOR encoding.

## 6. Encoder behavior

An encoder MUST:

1. Encode or receive exactly one CBOR payload item.
2. Determine the encoded payload length before writing the frame prefix.
3. Reject an empty payload, a payload larger than `2^32 - 1`, or a payload
   larger than its application limit.
4. Write `d9 cb f4 5a`.
5. Write the payload length as an unsigned 32-bit big-endian integer.
6. Write exactly that many payload bytes.

An encoder SHOULD submit a complete frame to a serialized stream writer so
that concurrent producers cannot interleave frame bytes.

## 7. Decoder behavior

A byte-stream decoder can process a frame as follows:

1. Read exactly eight bytes.
2. Verify that bytes 0 through 3 are `d9 cb f4 5a`.
3. Decode bytes 4 through 7 as the unsigned 32-bit payload length `N`.
4. Reject `N = 0` or `N` greater than the application limit.
5. Read exactly `N` payload bytes.
6. Verify, either immediately or at the application boundary, that the payload
   encodes exactly one well-formed CBOR item.

If the prefix, length, or payload is invalid, the decoder MUST report a framing
error. This specification defines no resynchronization marker. A connection-
oriented transport SHOULD close the affected connection unless its containing
protocol defines a safe recovery mechanism.

A generic, variation-tolerant CBOR decoder can decode the complete frame as an
unknown tag containing a byte string. Such a decoder will not automatically
interpret the byte string as nested CBOR unless it implements this tag's
semantics. A decoder configured to require RFC 8949 core deterministic encoding
can reject the forced 32-bit byte-string length for shorter payloads.

## 8. Concatenation and stream use

Frames MAY be concatenated without separators. The result is a CBOR Sequence
as defined by [RFC 8742](https://www.rfc-editor.org/rfc/rfc8742.html), where
each sequence element is one tagged frame.

The frame length applies only to the byte string in its own frame. It does not
include the eight-byte prefix or any subsequent frame. There is no end-of-
stream marker; the containing transport defines connection or stream closure.

## 9. Examples and test vectors

### 9.1 One-byte unsigned integer

The payload `00` is the CBOR unsigned integer zero:

```text
d9 cb f4 5a 00 00 00 01 00
```

### 9.2 One-byte empty map

The payload `a0` is an empty CBOR map:

```text
d9 cb f4 5a 00 00 00 01 a0
```

### 9.3 Four-byte payload

The payload `83 01 02 03` is the CBOR array `[1, 2, 3]`:

```text
d9 cb f4 5a 00 00 00 04 83 01 02 03
```

### 9.4 Invalid encodings

The following are invalid CBF4 frames:

| Encoding | Reason |
|---|---|
| `d9 cb f4 5a 00 00 00 00` | Empty payload cannot contain a CBOR item |
| `d9 cb f4 41 00` | Byte-string length does not use the required 32-bit form |
| `d9 cb f4 5a 00 00 00 02 00` | Payload is truncated |
| `d9 cb f4 5a 00 00 00 02 00 00` | Payload contains two CBOR items |
| `d9 cb f4 5a 00 00 00 01 ff` | Payload is not a well-formed CBOR item |

## 10. Design considerations

### 10.1 Why a byte string

A CBOR tag encloses exactly one data item. A tagged byte string makes the frame
one valid CBOR item and uses the existing byte-string length argument as the
transport length. A separate integer followed by raw bytes would instead be a
CBOR Sequence and would not be entirely enclosed by the tag.

### 10.2 Why a fixed 32-bit length

A 32-bit length supports payloads up to `2^32 - 1` bytes while allowing the
receiver to fetch the complete prefix with one fixed-size read. Applications
are expected to impose substantially smaller limits.

### 10.3 Why tag 52212

The hexadecimal value `0xCBF4` is mnemonic for "CBOR frame, four-byte length."
It is above 32767, placing it in the First Come First Served registration range,
and it has a preferred three-byte tag encoding. Combined with the five-byte
byte-string head, it produces the eight-byte prefix.

The value remains provisional until IANA assigns it.

### 10.4 Relationship to tag 24

Both tag 24 and this tag contain a byte string whose bytes encode one CBOR data
item. Tag 24 does not constrain the serialization width of the byte-string
length. This tag adds that constraint for byte-stream framing. Applications
that do not need a fixed prefix SHOULD use tag 24 instead.

## 11. Security considerations

The length field is controlled by the sender and MUST be treated as untrusted.
Decoders MUST reject lengths above an application limit before allocating
memory. Implementations SHOULD use checked integer conversions when converting
the unsigned 32-bit length to a platform-dependent size type.

The payload is also untrusted CBOR input. Payload decoders SHOULD enforce limits
on nesting depth, collection size, string size, and total processing work.
Valid framing does not imply that the enclosed item is valid for an
application protocol.

This framing provides no confidentiality, integrity, authentication, replay
protection, or peer authorization. Applications requiring those properties
must provide them in the containing protocol or transport.

A malformed frame can make the boundary of subsequent data unreliable. Unless
a containing protocol defines resynchronization, implementations SHOULD stop
processing that stream after a framing error.

## 12. IANA considerations

This document requests the following entry in the
[Concise Binary Object Representation (CBOR) Tags](https://www.iana.org/assignments/cbor-tags/cbor-tags.xhtml)
registry:

| Field | Requested value |
|---|---|
| Tag | 52212 (`0xCBF4`) |
| Data item | Byte string |
| Semantics | Fixed-32-bit-length byte string containing exactly one encoded CBOR data item |
| Point of contact | Jaremy Creechley (`creechley@gmail.com`) |
| Description of semantics | `https://github.com/elcritch/sigils/blob/main/docs/cbor-fixed32-frame.md` |

The requested value is in the First Come First Served range defined by
[RFC 8949 Section 9.2](https://www.rfc-editor.org/rfc/rfc8949.html#section-9.2).
The requester should verify that tag 52212 remains unassigned immediately before
submitting the registration request.

## 13. References

- [RFC 8126: Guidelines for Writing an IANA Considerations Section in RFCs](https://www.rfc-editor.org/rfc/rfc8126.html)
- [RFC 8174: Ambiguity of Uppercase vs Lowercase in RFC 2119 Key Words](https://www.rfc-editor.org/rfc/rfc8174.html)
- [RFC 8742: Concise Binary Object Representation (CBOR) Sequences](https://www.rfc-editor.org/rfc/rfc8742.html)
- [RFC 8949: Concise Binary Object Representation (CBOR)](https://www.rfc-editor.org/rfc/rfc8949.html)
- [IANA CBOR Tags Registry](https://www.iana.org/assignments/cbor-tags/cbor-tags.xhtml)
