## Bounded length framing for reliable Chronos streams.

import chronos

const DefaultIpcMaxFrameSize* = 16 * 1024 * 1024 ## Default 16 MiB frame limit.

type IpcFrameError* = object of CatchableError ## Invalid or incomplete frame.

proc framePayload*(
    payload: string,
    maxFrameSize = DefaultIpcMaxFrameSize,
): string =
  ## Prefix a payload with its unsigned 32-bit big-endian length.
  if maxFrameSize <= 0:
    raise newException(IpcFrameError, "IPC frame size limit must be positive")
  if payload.len == 0:
    raise newException(IpcFrameError, "IPC frames must not be empty")
  if payload.len > maxFrameSize or uint64(payload.len) > uint64(high(uint32)):
    raise newException(IpcFrameError, "IPC frame exceeds configured size limit")

  let size = uint32(payload.len)
  result = newString(payload.len + 4)
  result[0] = char((size shr 24) and 0xff)
  result[1] = char((size shr 16) and 0xff)
  result[2] = char((size shr 8) and 0xff)
  result[3] = char(size and 0xff)
  copyMem(addr result[4], unsafeAddr payload[0], payload.len)

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
  ## Read one complete frame, validating its length before allocation.
  if maxFrameSize <= 0:
    raise newException(IpcFrameError, "IPC frame size limit must be positive")
  var header = newString(4)
  await transport.readExactly(addr header[0], header.len)

  let size =
    (uint32(uint8(header[0])) shl 24) or
    (uint32(uint8(header[1])) shl 16) or
    (uint32(uint8(header[2])) shl 8) or
    uint32(uint8(header[3]))
  if size == 0:
    raise newException(IpcFrameError, "IPC frames must not be empty")
  if uint64(size) > uint64(maxFrameSize):
    raise newException(IpcFrameError, "IPC frame exceeds configured size limit")

  result = newString(int(size))
  await transport.readExactly(addr result[0], result.len)
