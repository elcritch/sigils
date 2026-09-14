## Transport-independent tagged CBOR stream framing.

when not defined(features.sigils.cbor) and
    not defined(features.sigils.ipc):
  {.error: "enable the sigils 'cbor' or 'ipc' package feature before importing CBOR RPC".}

import std/options
import cborious

export options

const
  DefaultCborRpcMaxFrameSize* = 16 * 1024 * 1024
  CborRpcFrameTag* = CborTag(24'u64)
  CborRpcFrameHeaderSize = 7
  CborRpcFramePrefix = [0xd8'u8, 0x18'u8, 0x5a'u8]

type CborRpcFrameError* = object of CatchableError
  ## Invalid or incomplete CBOR RPC frame.

type CborRpcFrameParser* = object
  ## Incremental parser for tagged, length-prefixed CBOR RPC frames.
  buffer: string
  maxFrameSize: int

proc frameCborRpcPayload*(
    payload: string,
    maxFrameSize = DefaultCborRpcMaxFrameSize,
): string =
  ## Wrap a CBOR payload in a tagged, definite-length CBOR byte string.
  if maxFrameSize <= 0:
    raise newException(CborRpcFrameError, "CBOR RPC frame size limit must be positive")
  if payload.len == 0:
    raise newException(CborRpcFrameError, "CBOR RPC frames must not be empty")
  if payload.len > maxFrameSize or uint64(payload.len) > uint64(high(uint32)):
    raise newException(
      CborRpcFrameError,
      "CBOR RPC frame exceeds configured size limit",
    )

  var stream = CborStream.init(payload.len + CborRpcFrameHeaderSize)
  stream.cborPackTag(CborRpcFrameTag)
  stream.writeInitial(CborMajor.Binary, 26'u8)
  stream.store32(uint32(payload.len))
  stream.write(payload)
  result = move stream.data

proc initCborRpcFrameParser*(
    maxFrameSize = DefaultCborRpcMaxFrameSize,
): CborRpcFrameParser =
  ## Initialize an incremental CBOR RPC frame parser.
  if maxFrameSize <= 0:
    raise newException(CborRpcFrameError, "CBOR RPC frame size limit must be positive")
  CborRpcFrameParser(maxFrameSize: maxFrameSize)

proc add*(parser: var CborRpcFrameParser, data: string) =
  ## Append bytes received from any stream transport.
  parser.buffer.add(data)

proc nextFrame*(parser: var CborRpcFrameParser): Option[string] =
  ## Return the next complete payload, or none when more bytes are needed.
  if parser.maxFrameSize <= 0:
    raise newException(CborRpcFrameError, "CBOR RPC frame parser is not initialized")
  if parser.buffer.len < CborRpcFrameHeaderSize:
    return none(string)

  for index, expected in CborRpcFramePrefix:
    if parser.buffer[index].uint8 != expected:
      raise newException(CborRpcFrameError, "unexpected CBOR RPC frame prefix")

  let size =
    (uint32(parser.buffer[3].uint8) shl 24) or
    (uint32(parser.buffer[4].uint8) shl 16) or
    (uint32(parser.buffer[5].uint8) shl 8) or
    uint32(parser.buffer[6].uint8)
  if size == 0:
    raise newException(CborRpcFrameError, "CBOR RPC frames must not be empty")
  if uint64(size) > uint64(parser.maxFrameSize):
    raise newException(
      CborRpcFrameError,
      "CBOR RPC frame exceeds configured size limit",
    )

  let frameEnd = CborRpcFrameHeaderSize + int(size)
  if parser.buffer.len < frameEnd:
    return none(string)

  let payload = parser.buffer[CborRpcFrameHeaderSize..<frameEnd]
  if frameEnd == parser.buffer.len:
    parser.buffer.setLen(0)
  else:
    parser.buffer = parser.buffer[frameEnd..^1]
  some(payload)
