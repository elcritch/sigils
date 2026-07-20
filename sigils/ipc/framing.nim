## Tagged CBOR framing for reliable Chronos streams.

import cborious
import chronos

const
  DefaultIpcMaxFrameSize* = 16 * 1024 * 1024 ## Default 16 MiB frame limit.
  IpcFrameTag* = CborTag(52_212'u64)         ## Provisional CBF4 fixed-width frame tag.
  IpcFrameHeaderSize = 8
  IpcFramePrefix = [0xd9'u8, 0xcb'u8, 0xf4'u8, 0x5a'u8]

type IpcFrameError* = object of CatchableError ## Invalid or incomplete frame.

proc framePayload*(
    payload: string,
    maxFrameSize = DefaultIpcMaxFrameSize,
): string =
  ## Wrap a CBOR payload in a tagged, definite-length CBOR byte string.
  if maxFrameSize <= 0:
    raise newException(IpcFrameError, "IPC frame size limit must be positive")
  if payload.len == 0:
    raise newException(IpcFrameError, "IPC frames must not be empty")
  if payload.len > maxFrameSize or uint64(payload.len) > uint64(high(uint32)):
    raise newException(IpcFrameError, "IPC frame exceeds configured size limit")

  var stream = CborStream.init(payload.len + IpcFrameHeaderSize)
  stream.cborPackTag(IpcFrameTag)
  stream.writeInitial(CborMajor.Binary, 26'u8)
  stream.store32(uint32(payload.len))
  stream.write(payload)
  result = move stream.data

proc writeFrame*(
    transport: StreamTransport,
    payload: string,
    maxFrameSize = DefaultIpcMaxFrameSize,
) {.async.} =
  ## Queue one complete frame as one Chronos transport write.
  let frame = framePayload(payload, maxFrameSize)
  let written = await transport.write(frame)
  if written != frame.len:
    raise newException(IpcFrameError, "Chronos did not write the complete IPC frame")

proc readFrame*(
    transport: StreamTransport,
    maxFrameSize = DefaultIpcMaxFrameSize,
): Future[string] {.async.} =
  ## Read one tagged CBOR byte string, validating its length before allocation.
  if maxFrameSize <= 0:
    raise newException(IpcFrameError, "IPC frame size limit must be positive")

  var header: array[IpcFrameHeaderSize, uint8]
  await transport.readExactly(addr header[0], header.len)
  for index, expected in IpcFramePrefix:
    if header[index] != expected:
      raise newException(IpcFrameError, "unexpected CBOR IPC frame prefix")

  let size =
    (uint32(header[4]) shl 24) or
    (uint32(header[5]) shl 16) or
    (uint32(header[6]) shl 8) or
    uint32(header[7])
  if size == 0:
    raise newException(IpcFrameError, "IPC frames must not be empty")
  if uint64(size) > uint64(maxFrameSize):
    raise newException(IpcFrameError, "IPC frame exceeds configured size limit")

  result = newString(int(size))
  await transport.readExactly(addr result[0], result.len)
