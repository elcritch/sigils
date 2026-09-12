import std/[json, jsonutils, strutils, syncio, tables]
import cloneutils
import features

export cloneutils, features

when not sigilsSigilNameStringEnabled:
  import stack_strings

export tables
when not sigilsSigilNameStringEnabled:
  export stack_strings

type FastErrorCodes* = enum
  # Error messages
  FAST_PARSE_ERROR = -27
  INVALID_REQUEST = -26
  METHOD_NOT_FOUND = -25
  INVALID_PARAMS = -24
  INTERNAL_ERROR = -23
  SERVER_ERROR = -22

when sigilsSigilNameStringEnabled:
  type SigilName* = string
else:
  type SigilName* = StackString[48]

type
  SigilRpcEncodeError* = object of CatchableError ## Remote RPC encode failure.
  SigilRpcDecodeError* = object of CatchableError ## Remote RPC decode failure.

  RpcWireFormat* {.pure.} = enum
    Cbor
    Json

when defined(features.sigils.ipc):
  type
    SigilIpcEncodeError* = SigilRpcEncodeError
    SigilIpcDecodeError* = SigilRpcDecodeError

when defined(nimscript) or defined(useJsonSerde) or defined(sigilsJsonSerde):
  export json
elif sigilsCborSerdeEnabled:
  import cborious
  export cborious
else:
  import svariant
  when sigilsCborRpcEnabled:
    import cborious
  export svariant
  when sigilsCborRpcEnabled:
    # Cborious serialization generics resolve their packers at instantiation.
    export cborious

type SigilParams* {.acyclic.} = object ## Implementation-specific call payload.
  when defined(nimscript) or defined(useJsonSerde) or defined(sigilsJsonSerde):
    payload*: JsonNode
  elif sigilsCborSerdeEnabled:
    payload*: CborStream
  else:
    payload*: Variant
    cloner*: VariantCloner
  wireFormat*: RpcWireFormat
  wireData*: string

type
  RequestType* {.size: sizeof(uint8).} = enum
    # Fast RPC Types
    Request = 5
    Response = 6
    Notify = 7
    Error = 8
    Subscribe = 9
    Publish = 10
    SubscribeStop = 11
    PublishDone = 12
    SystemRequest = 19
    Unsupported = 23
    # rtpMax = 23 # numbers less than this store in single mpack/cbor byte

  SigilId* = distinct int

  SigilRequest* = object
    kind*: RequestType
    origin*: SigilId
    procName*: SigilName
    params*: SigilParams # - we handle params below

  SigilRequestTy*[T] = SigilRequest

  SigilResponse* = object
    kind*: RequestType
    id*: int
    result*: SigilParams # - we handle params below

  SigilError* = ref object
    code*: FastErrorCodes
    msg*: string # trace*: seq[(string, string, int)]

type
  ConversionError* = object of CatchableError

  SigilErrorStackTrace* = object
    code*: int
    msg*: string
    stacktrace*: seq[string]

func compareSigilName*(a, b: SigilName): int {.inline.} =
  when sigilsSigilNameStringEnabled:
    cmp(a, b)
  else:
    cmp($a, $b)

proc clone*(
    params: SigilParams, mode: CloneMode = defaultCloneMode
): SigilParams =
  when defined(nimscript) or defined(useJsonSerde) or defined(sigilsJsonSerde):
    result.payload = params.payload
  elif sigilsCborSerdeEnabled:
    result.payload = params.payload
  else:
    if not params.payload.isNil:
      if params.cloner.isNil:
        raise newException(ValueError, "cannot clone SigilParams without a cloner")
      result.payload = params.cloner(
        params.payload, deliveryCloneMode(mode)
      )
      result.cloner = params.cloner
  result.wireFormat = params.wireFormat
  result.wireData = params.wireData

proc clone*(
    req: SigilRequest, mode: CloneMode = defaultCloneMode
): SigilRequest =
  result = SigilRequest(
    kind: req.kind,
    origin: req.origin,
    procName: req.procName,
    params: req.params.clone(mode),
  )

proc `$`*(id: SigilId): string =
  "0x" & id.int.toHex(16)

proc rpcPack*(res: SigilParams): SigilParams {.inline.} =
  result = res

proc rpcPack*[T](res: sink T): SigilParams =
  when defined(nimscript) or defined(useJsonSerde) or defined(sigilsJsonSerde):
    let jn = toJson(res)
    result = SigilParams(payload: jn)
  elif sigilsCborSerdeEnabled:
    var buf {.global, threadvar.}: CborStream
    buf = CborStream.init()
    buf.setPosition(0)
    buf.pack(res)
    result = SigilParams(payload: buf)
  else:
    result = SigilParams(
      payload: newOwnedVariant(ensureMove(res)),
      cloner: clonerFor(T),
    )

proc initRpcParams*(format: RpcWireFormat, data: sink string): SigilParams =
  ## Build type-erased parameters decoded by generated slots and selectors.
  result = SigilParams(wireFormat: format, wireData: data)

proc hasRpcData*(params: SigilParams): bool =
  params.wireData.len > 0

proc rpcData*(params: SigilParams): string =
  params.wireData

proc unpackJsonTuple[T](node: JsonNode): T =
  if node.kind != JArray:
    return jsonTo(node, T)

  var fieldCount = 0
  for _ in fields(result):
    fieldCount.inc()
  if node.len != fieldCount:
    raise newException(
      ValueError,
      "JSON parameter count mismatch: expected " & $fieldCount &
        ", got " & $node.len,
    )

  var index = 0
  for field in fields(result):
    fromJson(field, node[index])
    index.inc()

proc rpcPackRemote*[T](
    res: sink T, format: RpcWireFormat
): SigilParams =
  ## Preserve the local representation and attach a remote wire encoding.
  case format
  of RpcWireFormat.Cbor:
    when sigilsCborRpcEnabled:
      when compiles(cborious.toCbor(res)):
        let encoded =
          try:
            cborious.toCbor(res)
          except CatchableError as error:
            raise newException(SigilRpcEncodeError, error.msg)
        result = rpcPack(ensureMove(res))
        result.wireFormat = format
        result.wireData = encoded
      else:
        raise newException(
          SigilRpcEncodeError,
          "type cannot be encoded as RPC CBOR",
        )
    else:
      raise newException(SigilRpcEncodeError, "CBOR RPC support is disabled")
  of RpcWireFormat.Json:
    when compiles(toJson(res)):
      let encoded =
        try:
          $toJson(res)
        except CatchableError as error:
          raise newException(SigilRpcEncodeError, error.msg)
      result = rpcPack(ensureMove(res))
      result.wireFormat = format
      result.wireData = encoded
    else:
      raise newException(
        SigilRpcEncodeError,
        "type cannot be encoded as RPC JSON",
      )

when defined(features.sigils.ipc):
  proc initIpcParams*(data: sink string): SigilParams =
    ## Build type-erased parameters that generated slots/selectors decode from CBOR.
    initRpcParams(RpcWireFormat.Cbor, data)

  proc hasIpcData*(params: SigilParams): bool =
    params.hasRpcData() and params.wireFormat == RpcWireFormat.Cbor

  proc ipcData*(params: SigilParams): string =
    if params.hasIpcData():
      result = params.rpcData()

  proc rpcPackIpc*[T](res: sink T): SigilParams =
    ## Preserve the local representation and attach CBOR for an IPC response.
    rpcPackRemote(ensureMove(res), RpcWireFormat.Cbor)

proc rpcUnpack*[T](obj: var T, ss: SigilParams) =
  if ss.hasRpcData():
    case ss.wireFormat
    of RpcWireFormat.Cbor:
      when sigilsCborRpcEnabled:
        when compiles(cborious.fromCbor("", T)):
          try:
            obj = cborious.fromCbor(ss.wireData, T)
          except CatchableError as error:
            raise newException(SigilRpcDecodeError, error.msg)
        else:
          raise newException(
            SigilRpcDecodeError,
            "type cannot be decoded from RPC CBOR",
          )
      else:
        raise newException(SigilRpcDecodeError, "CBOR RPC support is disabled")
    of RpcWireFormat.Json:
      when compiles(jsonTo(parseJson("null"), T)):
        try:
          let node = parseJson(ss.wireData)
          when T is tuple:
            obj = unpackJsonTuple[T](node)
          else:
            obj = jsonTo(node, T)
        except CatchableError as error:
          raise newException(SigilRpcDecodeError, error.msg)
      else:
        raise newException(
          SigilRpcDecodeError,
          "type cannot be decoded from RPC JSON",
        )
    return

  when defined(nimscript) or defined(useJsonSerde) or defined(sigilsJsonSerde):
    obj.fromJson(ss.payload)
  elif sigilsCborSerdeEnabled:
    ss.payload.setPosition(0)
    obj = unpack(ss.payload, T)
  else:
    assert not ss.payload.isNil
    obj = ss.payload.get(T)

proc wrapResponse*(id: SigilId, resp: SigilParams,
    kind = Response): SigilResponse =
  # echo "WRAP RESP: ", id, " kind: ", kind
  result.kind = kind
  result.id = id.int
  result.result = resp

proc wrapResponseError*(id: SigilId, err: SigilError): SigilResponse =
  stderr.writeLine("WRAP ERROR: ", id, " err: ", err.repr)
  result.kind = Error
  result.id = id.int
  result.result = rpcPack(err)

proc initSigilRequest*[S, T](
    procName: SigilName,
    args: sink T,
    origin: SigilId = SigilId(-1),
    reqKind: RequestType = Request,
): SigilRequestTy[S] =
  result = SigilRequestTy[S](
    kind: reqKind,
    origin: origin,
    procName: procName,
    params: rpcPack(ensureMove args)
  )

const sigilsMaxSignalLength* {.intdefine.} = 48

when sigilsSigilNameStringEnabled:
  proc toSigilName*(name: static string): SigilName =
    return name

  proc toSigilName*(name: string): SigilName =
    return name
else:
  proc toSigilName*(name: IndexableChars): SigilName =
    return toStackString(name, sigilsMaxSignalLength)

  proc toSigilName*(name: static string): SigilName =
    return toStackString(name, sigilsMaxSignalLength)

  proc toSigilName*(name: string): SigilName =
    return toStackString(name, sigilsMaxSignalLength)

template sigName*(name: static string): SigilName =
  ## Static Signal Name template
  toSigilName(name)

template sn*(name: static string): SigilName =
  ## Static Signal Name template
  toSigilName(name)

const AnySigilName* = toSigilName(":any:")
