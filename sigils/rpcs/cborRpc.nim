## CBOR adaptation for the transport-independent Sigils RPC router.

when not defined(features.sigils.cbor) and
    not defined(features.sigils.ipc):
  {.error: "enable the sigils 'cbor' or 'ipc' package feature before importing CBOR RPC".}

import std/options

import cborious

import ../protocol
import router

export options, router

const
  CborRpcProtocolVersion* = 1'u8
  CborRpcInvalidRequest* = RpcInvalidRequest
  CborRpcMethodNotFound* = RpcMethodNotFound
  CborRpcInvalidParams* = RpcInvalidParams
  CborRpcInternalError* = RpcInternalError

type
  CborRpcProtocolError* = object of CatchableError
    ## Invalid CBOR or wire envelope.

  CborRpcMessageKind* {.size: sizeof(uint8).} = enum
    ## CBOR RPC envelope operation.
    CborRpcRequest
    CborRpcResponse
    CborRpcNotify
    CborRpcError

  CborRpcEnvelope* = object
    ## Transport-independent CBOR RPC message.
    version*: uint8
    kind*: CborRpcMessageKind
    id*: uint64
    target*: string
    name*: string
    payload*: seq[byte]
    errorCode*: int32
    errorMessage*: string

  CborRpcRouter* = RpcRouter

proc newCborRpcRouter*(): CborRpcRouter =
  ## Create an empty endpoint router for CBOR RPC.
  newRpcRouter()

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

proc packCborRpcPayload*[T](value: T): seq[byte] =
  ## Encode a typed RPC argument or result as nested CBOR bytes.
  when compiles(cborious.toCbor(value)):
    try:
      result = stringToBytes(cborious.toCbor(value))
    except CatchableError as error:
      raise newException(
        CborRpcProtocolError,
        "could not encode CBOR payload: " & error.msg,
      )
  else:
    raise newException(
      CborRpcProtocolError,
      "type cannot be encoded as CBOR RPC",
    )

proc unpackCborRpcPayload*[T](
    payload: openArray[byte], _: typedesc[T]
): T =
  ## Decode a typed RPC argument or result from nested CBOR bytes.
  when compiles(cborious.fromCbor("", T)):
    try:
      result = cborious.fromCbor(bytesToString(payload), T)
    except CatchableError as error:
      raise newException(
        CborRpcProtocolError,
        "invalid CBOR payload: " & error.msg,
      )
  else:
    raise newException(
      CborRpcProtocolError,
      "type cannot be decoded from CBOR RPC",
    )

proc encodeCborRpcEnvelope*(envelope: CborRpcEnvelope): string =
  ## Encode one transport-independent CBOR RPC message.
  try:
    result = cborious.toCbor(envelope)
  except CatchableError as error:
    raise newException(
      CborRpcProtocolError,
      "could not encode CBOR RPC message: " & error.msg,
    )

proc decodeCborRpcEnvelope*(data: sink string): CborRpcEnvelope =
  ## Decode and validate one transport-independent CBOR RPC message.
  try:
    result = cborious.fromCbor(data, CborRpcEnvelope)
  except CatchableError as error:
    raise newException(
      CborRpcProtocolError,
      "invalid CBOR RPC message: " & error.msg,
    )

  if result.version != CborRpcProtocolVersion:
    raise newException(
      CborRpcProtocolError,
      "unsupported CBOR RPC protocol version: " & $result.version,
    )
  case result.kind
  of CborRpcRequest:
    if result.target.len == 0 or result.name.len == 0:
      raise newException(
        CborRpcProtocolError,
        "CBOR RPC target and name must not be empty",
      )
    if result.id == 0:
      raise newException(CborRpcProtocolError, "CBOR RPC request id must not be zero")
  of CborRpcNotify:
    if result.target.len == 0 or result.name.len == 0:
      raise newException(
        CborRpcProtocolError,
        "CBOR RPC target and name must not be empty",
      )
  of CborRpcResponse, CborRpcError:
    if result.id == 0:
      raise newException(CborRpcProtocolError, "CBOR RPC response id must not be zero")

proc cborRpcRequestEnvelope*(
    id: uint64,
    target, name: string,
    payload: sink seq[byte],
): CborRpcEnvelope =
  ## Construct a correlated CBOR RPC request envelope.
  CborRpcEnvelope(
    version: CborRpcProtocolVersion,
    kind: CborRpcRequest,
    id: id,
    target: target,
    name: name,
    payload: payload,
  )

proc cborRpcNotifyEnvelope*(
    target, name: string,
    payload: sink seq[byte],
): CborRpcEnvelope =
  ## Construct a one-way CBOR RPC notification envelope.
  CborRpcEnvelope(
    version: CborRpcProtocolVersion,
    kind: CborRpcNotify,
    target: target,
    name: name,
    payload: payload,
  )

proc cborRpcResponseEnvelope*(
    id: uint64, payload: sink seq[byte]
): CborRpcEnvelope =
  ## Construct a successful correlated CBOR RPC response envelope.
  CborRpcEnvelope(
    version: CborRpcProtocolVersion,
    kind: CborRpcResponse,
    id: id,
    payload: payload,
  )

proc cborRpcErrorEnvelope*(
    id: uint64, code: int32, message: string
): CborRpcEnvelope =
  ## Construct a structured correlated CBOR RPC error envelope.
  CborRpcEnvelope(
    version: CborRpcProtocolVersion,
    kind: CborRpcError,
    id: id,
    errorCode: code,
    errorMessage: message,
  )

proc payloadFromParams(params: SigilParams): seq[byte] =
  let data = params.rpcData()
  if not params.hasRpcData() or params.wireFormat != RpcWireFormat.Cbor:
    let error = newException(
      RpcRouteError,
      "RPC handler did not encode a CBOR result",
    )
    error.code = CborRpcInternalError
    raise error
  stringToBytes(data)

proc handleRequest*(
    router: CborRpcRouter, envelope: CborRpcEnvelope
): CborRpcEnvelope =
  ## Dispatch a CBOR RPC request and produce its response envelope.
  let resultParams = router.dispatchRequest(
    envelope.target,
    envelope.name,
    initRpcParams(
      RpcWireFormat.Cbor,
      bytesToString(envelope.payload),
    ),
  )
  cborRpcResponseEnvelope(envelope.id, payloadFromParams(resultParams))

proc handleNotify*(router: CborRpcRouter, envelope: CborRpcEnvelope) =
  ## Dispatch a CBOR RPC notification to a registered signal.
  router.dispatchNotify(
    envelope.target,
    envelope.name,
    initRpcParams(
      RpcWireFormat.Cbor,
      bytesToString(envelope.payload),
    ),
  )

proc handleCborRpc*(
    router: CborRpcRouter, data: sink string
): Option[string] =
  ## Process one encoded CBOR RPC request or notification.
  let envelope = decodeCborRpcEnvelope(data)
  case envelope.kind
  of CborRpcRequest:
    var response: CborRpcEnvelope
    try:
      response = router.handleRequest(envelope)
    except RpcRouteError as error:
      response = cborRpcErrorEnvelope(envelope.id, error.code, error.msg)
    except CatchableError as error:
      response = cborRpcErrorEnvelope(
        envelope.id,
        CborRpcInternalError,
        error.msg,
      )
    some(encodeCborRpcEnvelope(response))
  of CborRpcNotify:
    try:
      router.handleNotify(envelope)
    except CatchableError:
      discard
    none(string)
  of CborRpcResponse, CborRpcError:
    raise newException(
      CborRpcProtocolError,
      "expected a CBOR RPC request or notification",
    )
