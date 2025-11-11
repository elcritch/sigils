import std/[tables, strutils]
import stack_strings

import svariant

export tables
export svariant
export stack_strings

type FastErrorCodes* = enum
  # Error messages
  FAST_PARSE_ERROR = -27
  INVALID_REQUEST = -26
  METHOD_NOT_FOUND = -25
  INVALID_PARAMS = -24
  INTERNAL_ERROR = -23
  SERVER_ERROR = -22

when defined(nimscript) or defined(useJsonSerde):
  import std/json
  export json

type SigilParams* {.acyclic.} = object ## implementation specific -- handles data buffer
  when defined(nimscript) or defined(useJsonSerde):
    buf*: JsonNode
  else:
    buf*: WVariant

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

  SigilName* = StackString[48]

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

proc `$`*(id: SigilId): string =
  "0x" & id.int.toHex(16)

var requestCache {.threadvar.}: WVariant

proc rpcPack*(res: SigilParams): SigilParams {.inline.} =
  result = res

proc rpcPack*[T](res: sink T): SigilParams =
  when defined(nimscript) or defined(useJsonSerde):
    let jn = toJson(res)
    result = SigilParams(buf: jn)
  else:
    if requestCache.isNil:
      requestCache = newWrapperVariant(res)
    requestCache.resetTo(res)
    result = SigilParams(buf: requestCache)

proc rpcUnpack*[T](obj: var T, ss: SigilParams) =
  when defined(nimscript) or defined(useJsonSerde):
    obj.fromJson(ss.buf)
    discard
  else:
    assert not ss.buf.isNil
    obj = ss.buf.getWrapped(T)

proc wrapResponse*(id: SigilId, resp: SigilParams, kind = Response): SigilResponse =
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
  # echo "SigilRequest: ", procName, " args: ", args.repr
  result = SigilRequestTy[S](
    kind: reqKind,
    origin: origin,
    procName: procName,
    params: rpcPack(ensureMove args)
  )

const sigilsMaxSignalLength* {.intdefine.} = 48

proc toSigilName*(name: IndexableChars): SigilName =
  return toStackString(name, sigilsMaxSignalLength)

proc toSigilName*(name: static string): SigilName =
  return toStackString(name, sigilsMaxSignalLength)

proc toSigilName*(name: string): SigilName =
  return toStackString(name, sigilsMaxSignalLength)

template sigName*(name: static string): SigilName =
  toSigilName(name)

const AnySigilName* = toSigilName(":any:")
