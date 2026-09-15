## Transport-independent routing between remote RPC calls and Sigils.

import std/tables

import ../[agents, core, selectors]

const
  RpcInvalidRequest* = -32600'i32
  RpcMethodNotFound* = -32601'i32
  RpcInvalidParams* = -32602'i32
  RpcInternalError* = -32603'i32

type
  RpcRouteError* = object of CatchableError
    ## A transport-independent RPC routing failure.
    code*: int32

  RpcParamsDecoder* = proc(data: string): SigilParams {.nimcall.}
    ## Decode transport bytes into a local Sigils payload.

  RpcResultEncoder* = proc(params: sink SigilParams): string {.nimcall.}
    ## Encode a local Sigils result into transport bytes.

  RpcSlotRoute = object
    receiver: Agent
    implementation: AgentProc
    decodeParams: RpcParamsDecoder
    encodeResult: RpcResultEncoder

  RpcSelectorRoute = object
    receiver: DynamicAgent
    selector: SigilName
    decodeParams: RpcParamsDecoder
    encodeResult: RpcResultEncoder

  RpcSignalRoute = object
    source: Agent
    name: SigilName
    decodeParams: RpcParamsDecoder

  RpcRouter* = ref object
    ## Registry of named local Sigils endpoints.
    slots: Table[(string, string), RpcSlotRoute]
    selectors: Table[(string, string), RpcSelectorRoute]
    signals: Table[(string, string), RpcSignalRoute]

proc routeError(code: int32, message: string): ref RpcRouteError =
  result = newException(RpcRouteError, message)
  result.code = code

proc validateRpcName(name: string) =
  when not sigilsSigilNameStringEnabled:
    if name.len > sigilsMaxSignalLength:
      raise routeError(
        RpcInvalidRequest,
        "RPC name exceeds the configured SigilName capacity",
      )

proc newRpcRouter*(): RpcRouter =
  ## Create an empty remote endpoint router.
  RpcRouter(
    slots: initTable[(string, string), RpcSlotRoute](),
    selectors: initTable[(string, string), RpcSelectorRoute](),
    signals: initTable[(string, string), RpcSignalRoute](),
  )

proc registerSlotRoute*(
    router: RpcRouter,
    target: string,
    name: string,
    receiver: Agent,
    implementation: AgentProc,
    decodeParams: RpcParamsDecoder,
    encodeResult: RpcResultEncoder,
) =
  ## Register a generated slot with transport-specific codecs.
  if router.isNil or receiver.isNil or implementation.isNil or
      decodeParams.isNil or encodeResult.isNil:
    raise newException(ValueError, "RPC slot registration must not be nil")
  if target.len == 0 or name.len == 0:
    raise newException(ValueError, "RPC slot target and name must not be empty")
  router.slots[(target, name)] = RpcSlotRoute(
    receiver: receiver,
    implementation: implementation,
    decodeParams: decodeParams,
    encodeResult: encodeResult,
  )

proc registerSelectorRoute*(
    router: RpcRouter,
    target: string,
    receiver: DynamicAgent,
    selector: SigilName,
    decodeParams: RpcParamsDecoder,
    encodeResult: RpcResultEncoder,
) =
  ## Register a dynamic selector with transport-specific codecs.
  if router.isNil or receiver.isNil or decodeParams.isNil or encodeResult.isNil:
    raise newException(ValueError, "RPC selector registration must not be nil")
  if target.len == 0:
    raise newException(ValueError, "RPC selector target must not be empty")
  if not receiver.respondsTo(selector):
    raise newException(
      ValueError,
      "receiver does not handle selector " & $selector,
    )
  router.selectors[(target, $selector)] = RpcSelectorRoute(
    receiver: receiver,
    selector: selector,
    decodeParams: decodeParams,
    encodeResult: encodeResult,
  )

proc registerSignalRoute*(
    router: RpcRouter,
    target: string,
    source: Agent,
    name: SigilName,
    decodeParams: RpcParamsDecoder,
) =
  ## Register a signal with a transport-specific argument decoder.
  if router.isNil or source.isNil or decodeParams.isNil:
    raise newException(ValueError, "RPC signal registration must not be nil")
  if target.len == 0:
    raise newException(ValueError, "RPC signal target must not be empty")
  if ($name).len == 0:
    raise newException(ValueError, "RPC signal name must not be empty")
  router.signals[(target, $name)] = RpcSignalRoute(
    source: source,
    name: name,
    decodeParams: decodeParams,
  )

proc dispatchRequest*(
    router: RpcRouter,
    target: string,
    name: string,
    data: string,
): string =
  ## Decode and dispatch a registered request, then encode its result.
  if router.isNil:
    raise routeError(RpcMethodNotFound, "peer has no RPC router")
  validateRpcName(name)

  let slotKey = (target, name)
  if router.slots.hasKey(slotKey):
    let route = router.slots[slotKey]
    try:
      let request = SigilRequest(
        kind: Request,
        origin: SigilId(-1),
        procName: toSigilName(name),
        params: route.decodeParams(data),
      )
      discard route.receiver.callMethod(
        ensureMove(request),
        route.implementation,
      )
    except SigilRpcDecodeError as error:
      raise routeError(RpcInvalidParams, error.msg)
    return route.encodeResult(rpcPack(true))

  let selectorKey = (target, name)
  if not router.selectors.hasKey(selectorKey):
    raise routeError(RpcMethodNotFound, "selector is not exposed: " & name)
  let route = router.selectors[selectorKey]

  var invocation = Invocation(
    selector: route.selector,
  )
  try:
    invocation.params = route.decodeParams(data)
    if not route.receiver.dispatch(invocation):
      raise routeError(RpcMethodNotFound, "selector was not handled: " & name)
  except SigilRpcDecodeError as error:
    raise routeError(RpcInvalidParams, error.msg)
  result = route.encodeResult(ensureMove(invocation.result))

proc dispatchNotify*(
    router: RpcRouter,
    target: string,
    name: string,
    data: string,
) =
  ## Decode and emit an incoming notification through a registered signal.
  let signalKey = (target, name)
  if router.isNil or not router.signals.hasKey(signalKey):
    raise routeError(RpcMethodNotFound, "unknown RPC signal target: " & target)
  validateRpcName(name)
  let route = router.signals[signalKey]

  try:
    let request = SigilRequest(
      kind: Notify,
      origin: SigilId(-1),
      procName: route.name,
      params: route.decodeParams(data),
    )
    route.source.callSlots(ensureMove(request))
  except SigilRpcDecodeError as error:
    raise routeError(RpcInvalidParams, error.msg)
