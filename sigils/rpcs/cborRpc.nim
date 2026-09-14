## CBOR adaptation for the transport-independent Sigils RPC router.

when not defined(features.sigils.cbor) and
    not defined(features.sigils.ipc):
  {.error: "enable the sigils 'cbor' or 'ipc' package feature before importing CBOR RPC".}

import std/options

import cborious

import ../[agents, protocol, selectors]
import router

export cborious, options, router

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

proc decodeCborParams[T](data: string): SigilParams =
  try:
    result = rpcPack(cborious.fromCbor(data, T))
  except CatchableError as error:
    raise newException(SigilRpcDecodeError, error.msg)

proc encodeCborResult[T](params: sink SigilParams): string =
  var value: T
  rpcUnpack(value, params)
  try:
    result = cborious.toCbor(value)
  except CatchableError as error:
    raise newException(SigilRpcEncodeError, error.msg)

proc registerSelector*[A, R](
    router: CborRpcRouter,
    target: string,
    receiver: DynamicAgent,
    selector: Selector[A, R],
) =
  ## Expose one typed selector using CBOR argument and result codecs.
  router.registerSelectorRoute(
    target,
    receiver,
    selector.name,
    decodeCborParams[A],
    encodeCborResult[R],
  )

proc registerSlot*[A](
    router: CborRpcRouter,
    target, name: string,
    receiver: Agent,
    implementation: AgentProcTy[A],
) =
  ## Expose one generated slot using its typed CBOR argument codec.
  router.registerSlotRoute(
    target,
    name,
    receiver,
    implementation,
    decodeCborParams[A],
    encodeCborResult[bool],
  )

proc registerSignal*[A](
    router: CborRpcRouter,
    target: string,
    source: Agent,
    signal: SignalDescriptor[A],
) =
  ## Expose one signal using its typed CBOR argument codec.
  router.registerSignalRoute(
    target,
    source,
    signal.name,
    decodeCborParams[A],
  )

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
  try:
    result = stringToBytes(cborious.toCbor(value))
  except CatchableError as error:
    raise newException(
      CborRpcProtocolError,
      "could not encode CBOR payload: " & error.msg,
    )

proc unpackCborRpcPayload*[T](
    payload: openArray[byte], _: typedesc[T]
): T =
  ## Decode a typed RPC argument or result from nested CBOR bytes.
  try:
    result = cborious.fromCbor(bytesToString(payload), T)
  except CatchableError as error:
    raise newException(
      CborRpcProtocolError,
      "invalid CBOR payload: " & error.msg,
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

proc handleRequest*(
    router: CborRpcRouter, envelope: CborRpcEnvelope
): CborRpcEnvelope =
  ## Dispatch a CBOR RPC request and produce its response envelope.
  let resultData = router.dispatchRequest(
    envelope.target,
    envelope.name,
    bytesToString(envelope.payload),
  )
  cborRpcResponseEnvelope(envelope.id, stringToBytes(resultData))

proc handleNotify*(router: CborRpcRouter, envelope: CborRpcEnvelope) =
  ## Dispatch a CBOR RPC notification to a registered signal.
  router.dispatchNotify(
    envelope.target,
    envelope.name,
    bytesToString(envelope.payload),
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
