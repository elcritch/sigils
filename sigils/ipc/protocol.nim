## CBOR wire messages shared by all Sigils IPC transports.

import cborious

const
  IpcProtocolVersion* = 1'u8      ## Current Sigils IPC envelope version.
  IpcInvalidRequest* = -32600'i32 ## The incoming request was malformed.
  IpcMethodNotFound* = -32601'i32 ## The target or method is not exposed.
  IpcInvalidParams* = -32602'i32  ## The request parameters could not be decoded.
  IpcInternalError* = -32603'i32  ## The exposed handler failed internally.

type
  IpcProtocolError* = object of CatchableError ## Invalid CBOR or wire envelope.

  IpcMessageKind* {.size: sizeof(uint8).} = enum ## IPC envelope operation.
    IpcRequest
    IpcResponse
    IpcNotify
    IpcError

  IpcEnvelope* = object   ## Transport-independent CBOR message.
    version*: uint8       ## Wire protocol version.
    kind*: IpcMessageKind ## Request, response, notification, or error.
    id*: uint64           ## Nonzero request correlation ID, or zero for notifications.
    target*: string       ## Router endpoint name.
    name*: string         ## Slot, signal, or selector name.
    payload*: seq[byte]   ## Nested typed CBOR argument or result.
    errorCode*: int32     ## Structured code when ``kind`` is ``IpcError``.
    errorMessage*: string ## Human-readable remote failure detail.

proc bytesToString*(data: openArray[byte]): string =
  ## Copy binary bytes into Nim's binary-safe string representation.
  result = newString(data.len)
  if data.len > 0:
    copyMem(addr result[0], unsafeAddr data[0], data.len)

proc stringToBytes*(data: string): seq[byte] =
  ## Copy a binary-safe Nim string into bytes.
  result = newSeq[byte](data.len)
  if data.len > 0:
    copyMem(addr result[0], unsafeAddr data[0], data.len)

proc packIpcPayload*[T](value: T): seq[byte] =
  ## Encode a typed RPC argument or result as nested CBOR bytes.
  when compiles(cborious.toCbor(value)):
    try:
      result = stringToBytes(cborious.toCbor(value))
    except CatchableError as error:
      raise newException(IpcProtocolError, "could not encode CBOR payload: " & error.msg)
  else:
    raise newException(IpcProtocolError, "type cannot be encoded as IPC CBOR")

proc unpackIpcPayload*[T](payload: openArray[byte], _: typedesc[T]): T =
  ## Decode a typed RPC argument or result from nested CBOR bytes.
  when compiles(cborious.fromCbor("", T)):
    try:
      result = cborious.fromCbor(bytesToString(payload), T)
    except CatchableError as error:
      raise newException(IpcProtocolError, "invalid CBOR payload: " & error.msg)
  else:
    raise newException(IpcProtocolError, "type cannot be decoded from IPC CBOR")

proc encodeEnvelope*(envelope: IpcEnvelope): string =
  ## Encode one transport-independent IPC message.
  try:
    result = cborious.toCbor(envelope)
  except CatchableError as error:
    raise newException(IpcProtocolError, "could not encode IPC message: " & error.msg)

proc decodeEnvelope*(data: sink string): IpcEnvelope =
  ## Decode and validate one transport-independent IPC message.
  try:
    result = cborious.fromCbor(data, IpcEnvelope)
  except CatchableError as error:
    raise newException(IpcProtocolError, "invalid IPC message: " & error.msg)

  if result.version != IpcProtocolVersion:
    raise newException(
      IpcProtocolError,
      "unsupported IPC protocol version: " & $result.version,
    )
  case result.kind
  of IpcRequest:
    if result.target.len == 0 or result.name.len == 0:
      raise newException(IpcProtocolError, "IPC target and name must not be empty")
    if result.id == 0:
      raise newException(IpcProtocolError, "IPC request id must not be zero")
  of IpcNotify:
    if result.target.len == 0 or result.name.len == 0:
      raise newException(IpcProtocolError, "IPC target and name must not be empty")
  of IpcResponse, IpcError:
    if result.id == 0:
      raise newException(IpcProtocolError, "IPC response id must not be zero")

proc requestEnvelope*(
    id: uint64,
    target: string,
    name: string,
    payload: sink seq[byte],
): IpcEnvelope =
  ## Construct a correlated request envelope.
  IpcEnvelope(
    version: IpcProtocolVersion,
    kind: IpcRequest,
    id: id,
    target: target,
    name: name,
    payload: payload,
  )

proc notifyEnvelope*(
    target: string,
    name: string,
    payload: sink seq[byte],
): IpcEnvelope =
  ## Construct a one-way notification envelope.
  IpcEnvelope(
    version: IpcProtocolVersion,
    kind: IpcNotify,
    target: target,
    name: name,
    payload: payload,
  )

proc responseEnvelope*(id: uint64, payload: sink seq[byte]): IpcEnvelope =
  ## Construct a successful correlated response envelope.
  IpcEnvelope(
    version: IpcProtocolVersion,
    kind: IpcResponse,
    id: id,
    payload: payload,
  )

proc errorEnvelope*(id: uint64, code: int32, message: string): IpcEnvelope =
  ## Construct a structured correlated error envelope.
  IpcEnvelope(
    version: IpcProtocolVersion,
    kind: IpcError,
    id: id,
    errorCode: code,
    errorMessage: message,
  )
