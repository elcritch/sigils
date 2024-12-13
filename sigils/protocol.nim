import tables
import variant

export tables
export variant

type
  FastErrorCodes* = enum
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

type
  RpcParams* = object
    ## implementation specific -- handles data buffer
    when defined(nimscript) or defined(useJsonSerde):
      buf*: JsonNode
    else:
      buf*: Variant

type
  AgentType* {.size: sizeof(uint8).} = enum
    # Fast RPC Types
    Request       = 5
    Response      = 6
    Notify        = 7
    Error         = 8
    Subscribe     = 9
    Publish       = 10
    SubscribeStop = 11
    PublishDone   = 12
    SystemRequest = 19
    Unsupported   = 23
    # rtpMax = 23 # numbers less than this store in single mpack/cbor byte

  AgentId* = int

  AgentRequest* = object
    kind*: AgentType
    origin*: AgentId
    procName*: string
    params*: RpcParams # - we handle params below

  AgentRequestTy*[T] = AgentRequest

  AgentResponse* = object
    kind*: AgentType
    id*: int
    result*: RpcParams # - we handle params below

  AgentError* = ref object
    code*: FastErrorCodes
    msg*: string
    # trace*: seq[(string, string, int)]

method applyMethod*(ap: AgentRequest) {.base, gcsafe.} =
  discard

proc callMethod*(
    slot: AgentProc, ctx: RpcContext, req: AgentRequest, # clientId: ClientId,
): AgentResponse {.gcsafe, effectsOf: slot.} =
  ## Route's an rpc request. 

  if slot.isNil:
    let msg = req.procName & " is not a registered RPC method."
    let err = AgentError(code: METHOD_NOT_FOUND, msg: msg)
    result = wrapResponseError(req.origin, err)
  else:
    slot(ctx, req.params)
    let res = rpcPack(true)

    result = AgentResponse(kind: Response, id: req.origin, result: res)
