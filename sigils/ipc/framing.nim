## Chronos framing compatibility for generic CBOR-RPC frames.

import chronos

import ../rpcs/cbor/crFraming

export crFraming

const
  DefaultIpcMaxFrameSize* = DefaultCborRpcMaxFrameSize
  IpcFrameTag* = CborRpcFrameTag
  IpcFrameHeaderSize = 7

type IpcFrameError* = CborRpcFrameError

proc framePayload*(
    payload: string,
    maxFrameSize = DefaultIpcMaxFrameSize,
): string =
  ## Frame a payload using the compatibility IPC name.
  frameCborRpcPayload(payload, maxFrameSize)

proc writeFrame*(
    transport: StreamTransport,
    payload: string,
    maxFrameSize = DefaultIpcMaxFrameSize,
) {.async.} =
  ## Write one generic CBOR-RPC frame to a Chronos stream.
  let frame = frameCborRpcPayload(payload, maxFrameSize)
  let written = await transport.write(frame)
  if written != frame.len:
    raise newException(IpcFrameError, "Chronos did not write the complete IPC frame")

proc readFrame*(
    transport: StreamTransport,
    maxFrameSize = DefaultIpcMaxFrameSize,
): Future[string] {.async.} =
  ## Read one generic CBOR-RPC frame from a Chronos stream.
  if maxFrameSize <= 0:
    raise newException(IpcFrameError, "IPC frame size limit must be positive")

  var header: array[IpcFrameHeaderSize, uint8]
  await transport.readExactly(addr header[0], header.len)
  if header[0] != 0xd8'u8 or header[1] != 0x18'u8 or
      header[2] != 0x5a'u8:
    raise newException(IpcFrameError, "unexpected CBOR IPC frame prefix")

  let size =
    (uint32(header[3]) shl 24) or
    (uint32(header[4]) shl 16) or
    (uint32(header[5]) shl 8) or
    uint32(header[6])
  if size == 0:
    raise newException(IpcFrameError, "IPC frames must not be empty")
  if uint64(size) > uint64(maxFrameSize):
    raise newException(IpcFrameError, "IPC frame exceeds configured size limit")

  result = newString(int(size))
  await transport.readExactly(addr result[0], result.len)
