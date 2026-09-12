## Transport-independent routing between remote RPC calls and Sigils.

import std/[sets, tables]

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

  RpcSlotRoute = object
    receiver: Agent
    implementation: AgentProc

  RpcSelectorEndpoint = object
    receiver: DynamicAgent
    allowed: HashSet[string]

  RpcSignalEndpoint = object
    source: Agent
    allowed: HashSet[string]

  RpcRouter* = ref object
    ## Registry of named local Sigils endpoints.
    slots: Table[(string, string), RpcSlotRoute]
    selectors: Table[string, RpcSelectorEndpoint]
    signals: Table[string, RpcSignalEndpoint]

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
    selectors: initTable[string, RpcSelectorEndpoint](),
    signals: initTable[string, RpcSignalEndpoint](),
  )

proc registerSlot*(
    router: RpcRouter,
    target: string,
    name: string,
    receiver: Agent,
    implementation: AgentProc,
) =
  ## Expose one generated Sigils slot under a remote target and name.
  if router.isNil or receiver.isNil or implementation.isNil:
    raise newException(ValueError, "RPC slot registration must not be nil")
  if target.len == 0 or name.len == 0:
    raise newException(ValueError, "RPC slot target and name must not be empty")
  router.slots[(target, name)] = RpcSlotRoute(
    receiver: receiver,
    implementation: implementation,
  )

proc registerSelector*[A, R](
    router: RpcRouter,
    target: string,
    receiver: DynamicAgent,
    selector: Selector[A, R],
) =
  ## Expose one typed selector on a dynamic agent.
  if router.isNil or receiver.isNil:
    raise newException(ValueError, "RPC selector registration must not be nil")
  if target.len == 0:
    raise newException(ValueError, "RPC selector target must not be empty")
  if not receiver.respondsTo(selector):
    raise newException(
      ValueError,
      "receiver does not handle selector " & $selector.name,
    )
  var endpoint = router.selectors.getOrDefault(target)
  if not endpoint.receiver.isNil and endpoint.receiver != receiver:
    raise newException(ValueError, "RPC selector target already has a receiver")
  endpoint.receiver = receiver
  endpoint.allowed.incl($selector.name)
  router.selectors[target] = endpoint

proc registerProtocol*(
    router: RpcRouter,
    target: string,
    receiver: DynamicAgent,
    protocol: SigilProtocol,
) =
  ## Expose only the selectors declared by a conforming runtime protocol.
  if router.isNil or receiver.isNil:
    raise newException(ValueError, "RPC protocol registration must not be nil")
  if target.len == 0:
    raise newException(ValueError, "RPC protocol target must not be empty")
  if not receiver.conformsTo(protocol):
    raise newException(
      ProtocolConformanceError,
      "receiver does not conform to protocol " & $protocol.name,
    )

  var endpoint = router.selectors.getOrDefault(target)
  if not endpoint.receiver.isNil and endpoint.receiver != receiver:
    raise newException(ValueError, "RPC selector target already has a receiver")
  endpoint.receiver = receiver
  for requirement in protocol.requirements:
    endpoint.allowed.incl($requirement.selector)
  router.selectors[target] = endpoint

proc registerSignal*(
    router: RpcRouter,
    target: string,
    source: Agent,
    name: SigilName,
) =
  ## Allow one incoming notification to be emitted through a local signal.
  if router.isNil or source.isNil:
    raise newException(ValueError, "RPC signal registration must not be nil")
  if target.len == 0:
    raise newException(ValueError, "RPC signal target must not be empty")
  if ($name).len == 0:
    raise newException(ValueError, "RPC signal name must not be empty")
  var endpoint = router.signals.getOrDefault(target)
  if not endpoint.source.isNil and endpoint.source != source:
    raise newException(ValueError, "RPC signal target already has a source")
  endpoint.source = source
  endpoint.allowed.incl($name)
  router.signals[target] = endpoint

proc registerSignalProtocol*(
    router: RpcRouter,
    target: string,
    source: Agent,
    protocol: SigilProtocol,
) =
  ## Allow incoming notifications for the signals declared by a protocol.
  if router.isNil or source.isNil:
    raise newException(ValueError, "RPC signal registration must not be nil")
  if target.len == 0:
    raise newException(ValueError, "RPC signal target must not be empty")
  var endpoint = router.signals.getOrDefault(target)
  if not endpoint.source.isNil and endpoint.source != source:
    raise newException(ValueError, "RPC signal target already has a source")
  endpoint.source = source
  for signal in protocol.signals:
    endpoint.allowed.incl($signal.name)
  router.signals[target] = endpoint

proc dispatchRequest*(
    router: RpcRouter,
    target: string,
    name: string,
    params: sink SigilParams,
): SigilParams =
  ## Dispatch a remote request to a registered slot or selector.
  if router.isNil:
    raise routeError(RpcMethodNotFound, "peer has no RPC router")
  validateRpcName(name)

  let slotKey = (target, name)
  if router.slots.hasKey(slotKey):
    let route = router.slots[slotKey]
    let format = params.wireFormat
    let request = SigilRequest(
      kind: Request,
      origin: SigilId(-1),
      procName: toSigilName(name),
      params: params,
    )
    try:
      discard route.receiver.callMethod(ensureMove(request),
          route.implementation)
    except SigilRpcDecodeError as error:
      raise routeError(RpcInvalidParams, error.msg)
    return rpcPackRemote(true, format)

  if not router.selectors.hasKey(target):
    raise routeError(RpcMethodNotFound, "unknown RPC target: " & target)
  let endpoint = router.selectors[target]
  if name notin endpoint.allowed:
    raise routeError(RpcMethodNotFound, "selector is not exposed: " & name)

  var invocation = Invocation(
    selector: toSigilName(name),
    params: params,
  )
  try:
    if not endpoint.receiver.dispatch(invocation):
      raise routeError(RpcMethodNotFound, "selector was not handled: " & name)
  except SigilRpcDecodeError as error:
    raise routeError(RpcInvalidParams, error.msg)
  result = ensureMove(invocation.result)

proc dispatchNotify*(
    router: RpcRouter,
    target: string,
    name: string,
    params: sink SigilParams,
) =
  ## Emit an incoming notification through a registered local signal source.
  if router.isNil or not router.signals.hasKey(target):
    raise routeError(RpcMethodNotFound, "unknown RPC signal target: " & target)
  validateRpcName(name)
  let endpoint = router.signals[target]
  if name notin endpoint.allowed:
    raise routeError(RpcMethodNotFound, "signal is not exposed: " & name)

  let request = SigilRequest(
    kind: Notify,
    origin: SigilId(-1),
    procName: toSigilName(name),
    params: params,
  )
  endpoint.source.callSlots(ensureMove(request))
