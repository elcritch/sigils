import tables
import variant

export tables
export variant

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

type RpcParams* = object ## implementation specific -- handles data buffer
  when defined(nimscript) or defined(useJsonSerde):
    buf*: JsonNode
  else:
    buf*: Variant

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

  SigilId* = int

  SigilRequest* = object
    kind*: RequestType
    origin*: SigilId
    procName*: string
    params*: RpcParams # - we handle params below

  SigilRequestTy*[T] = SigilRequest

  AgentResponse* = object
    kind*: RequestType
    id*: int
    result*: RpcParams # - we handle params below

  AgentError* = ref object
    code*: FastErrorCodes
    msg*: string # trace*: seq[(string, string, int)]

type
  ConversionError* = object of CatchableError
  AgentSlotError* = object of CatchableError

  AgentErrorStackTrace* = object
    code*: int
    msg*: string
    stacktrace*: seq[string]

  AgentBindError* = object of ValueError
  AgentAddressUnresolvableError* = object of ValueError

proc pack*[T](ss: var Variant, val: T) =
  # echo "Pack Type: ", getTypeId(T), " <- ", typeof(val)
  ss = newVariant(val)

proc unpack*[T](ss: Variant, obj: var T) =
  # if ss.ofType(T):
  obj = ss.get(T)
  # else:
  # raise newException(ConversionError, "couldn't convert to: " & $(T))

proc rpcPack*(res: RpcParams): RpcParams {.inline.} =
  result = res

proc rpcPack*[T](res: T): RpcParams =
  when defined(nimscript) or defined(useJsonSerde):
    let jn = toJson(res)
    result = RpcParams(buf: jn)
  else:
    result = RpcParams(buf: newVariant(res))

proc rpcUnpack*[T](obj: var T, ss: RpcParams) =
  when defined(nimscript) or defined(useJsonSerde):
    obj.fromJson(ss.buf)
    discard
  else:
    ss.buf.unpack(obj)

proc wrapResponse*(id: SigilId, resp: RpcParams, kind = Response): AgentResponse =
  # echo "WRAP RESP: ", id, " kind: ", kind
  result.kind = kind
  result.id = id
  result.result = resp

proc wrapResponseError*(id: SigilId, err: AgentError): AgentResponse =
  echo "WRAP ERROR: ", id, " err: ", err.repr
  result.kind = Error
  result.id = id
  result.result = rpcPack(err)

template packResponse*(res: AgentResponse): Variant =
  var so = newVariant()
  so.pack(res)
  so
