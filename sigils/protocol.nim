import std/[tables, strutils]
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

when defined(feature.sigils.ipc):
  type
    SigilIpcEncodeError* = object of CatchableError ## IPC CBOR encode failure.
    SigilIpcDecodeError* = object of CatchableError ## IPC CBOR decode failure.

when defined(nimscript) or defined(useJsonSerde) or defined(sigilsJsonSerde):
  import std/json
  export json
elif sigilsCborSerdeEnabled:
  import cborious
  export cborious
else:
  import svariant
  when defined(feature.sigils.ipc):
    import cborious
  export svariant
  when defined(feature.sigils.ipc):
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
    when defined(feature.sigils.ipc):
      ipcData*: string

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

proc clone*(params: SigilParams): SigilParams =
  when defined(nimscript) or defined(useJsonSerde) or defined(sigilsJsonSerde):
    result.payload = params.payload
  elif sigilsCborSerdeEnabled:
    result.payload = params.payload
  else:
    if not params.payload.isNil:
      if params.cloner.isNil:
        raise newException(ValueError, "cannot clone SigilParams without a cloner")
      result.payload = params.cloner(params.payload)
      result.cloner = params.cloner
    when defined(feature.sigils.ipc):
      result.ipcData = params.ipcData

proc clone*(req: SigilRequest): SigilRequest =
  result = SigilRequest(
    kind: req.kind,
    origin: req.origin,
    procName: req.procName,
    params: req.params.clone(),
  )

proc `$`*(id: SigilId): string =
  "0x" & id.int.toHex(16)

proc rpcPack*(res: SigilParams): SigilParams {.inline.} =
  result = res

proc rpcPack*[T](res: sink T): SigilParams =
  when defined(nimscript) or defined(sigilsJsonSerde):
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

when defined(feature.sigils.ipc):
  proc initIpcParams*(data: sink string): SigilParams =
    ## Build type-erased parameters that generated slots/selectors decode from CBOR.
    when sigilsCborSerdeEnabled:
      result = SigilParams(payload: CborStream.init(data))
    else:
      result = SigilParams(ipcData: data)

  proc hasIpcData*(params: SigilParams): bool =
    when sigilsCborSerdeEnabled:
      not params.payload.isNil
    else:
      params.ipcData.len > 0

  proc ipcData*(params: SigilParams): string =
    when sigilsCborSerdeEnabled:
      if not params.payload.isNil:
        result = params.payload.data
    else:
      result = params.ipcData

  proc rpcPackIpc*[T](res: sink T): SigilParams =
    ## Preserve the local representation and attach CBOR for an IPC response.
    when sigilsCborSerdeEnabled:
      result = rpcPack(ensureMove res)
    else:
      when compiles(cborious.toCbor(res)):
        let encoded =
          try:
            cborious.toCbor(res)
          except CatchableError as error:
            raise newException(SigilIpcEncodeError, error.msg)
        result = rpcPack(ensureMove res)
        result.ipcData = encoded
      else:
        raise newException(
          SigilIpcEncodeError,
          "type cannot be encoded as IPC CBOR",
        )

proc rpcUnpack*[T](obj: var T, ss: SigilParams) =
  when defined(nimscript) or defined(useJsonSerde):
    obj.fromJson(ss.payload)
    discard
  elif sigilsCborSerdeEnabled:
    ss.payload.setPosition(0)
    obj = unpack(ss.payload, T)
  else:
    when defined(feature.sigils.ipc):
      if ss.ipcData.len > 0:
        when compiles(cborious.fromCbor("", T)):
          try:
            obj = cborious.fromCbor(ss.ipcData, T)
          except CatchableError as error:
            raise newException(SigilIpcDecodeError, error.msg)
        else:
          raise newException(
            SigilIpcDecodeError,
            "type cannot be decoded from IPC CBOR",
          )
      else:
        assert not ss.payload.isNil
        obj = ss.payload.get(T)
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
  echo "WRAP ERROR: ", id, " err: ", err.repr
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
