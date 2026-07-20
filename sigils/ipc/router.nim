## Routing between IPC messages and Sigils slots, signals, and selectors.

import std/[sets, tables]

import ../[agents, core, selectors]
import protocol

type
  IpcRouteError* = object of CatchableError ## An IPC routing failure.
    code*: int32 ## Structured error code returned to the remote caller.

  IpcSlotRoute = object
    receiver: Agent
    implementation: AgentProc

  IpcSelectorEndpoint = object
    receiver: DynamicAgent
    allowed: HashSet[string]

  IpcSignalEndpoint = object
    source: Agent
    allowed: HashSet[string]

  IpcRouter* = ref object ## Registry of named local Sigils endpoints.
    slots: Table[(string, string), IpcSlotRoute]
    selectors: Table[string, IpcSelectorEndpoint]
    signals: Table[string, IpcSignalEndpoint]

proc routeError(code: int32, message: string): ref IpcRouteError =
  result = newException(IpcRouteError, message)
  result.code = code

proc validateIpcName(name: string) =
  when not sigilsSigilNameStringEnabled:
    if name.len > sigilsMaxSignalLength:
      raise routeError(
        IpcInvalidRequest,
        "IPC name exceeds the configured SigilName capacity",
      )

proc newIpcRouter*(): IpcRouter =
  ## Create an empty endpoint router.
  IpcRouter(
    slots: initTable[(string, string), IpcSlotRoute](),
    selectors: initTable[string, IpcSelectorEndpoint](),
    signals: initTable[string, IpcSignalEndpoint](),
  )

proc payloadFromParams(params: SigilParams): seq[byte] =
  let data = params.ipcData()
  if data.len == 0:
    raise routeError(IpcInternalError, "IPC handler did not encode a result")
  stringToBytes(data)

proc paramsFromPayload(payload: openArray[byte]): SigilParams =
  initIpcParams(bytesToString(payload))

proc registerSlot*(
    router: IpcRouter,
    target: string,
    name: string,
    receiver: Agent,
    implementation: AgentProc,
) =
  ## Expose one generated Sigils slot under a remote target and name.
  if router.isNil or receiver.isNil or implementation.isNil:
    raise newException(ValueError, "IPC slot registration must not be nil")
  if target.len == 0 or name.len == 0:
    raise newException(ValueError, "IPC slot target and name must not be empty")
  router.slots[(target, name)] = IpcSlotRoute(
    receiver: receiver,
    implementation: implementation,
  )

proc registerSelector*[A, R](
    router: IpcRouter,
    target: string,
    receiver: DynamicAgent,
    selector: Selector[A, R],
) =
  ## Expose one typed selector on a dynamic agent.
  if router.isNil or receiver.isNil:
    raise newException(ValueError, "IPC selector registration must not be nil")
  if target.len == 0:
    raise newException(ValueError, "IPC selector target must not be empty")
  if not receiver.respondsTo(selector):
    raise newException(ValueError, "receiver does not handle selector " &
        $selector.name)
  var endpoint = router.selectors.getOrDefault(target)
  if not endpoint.receiver.isNil and endpoint.receiver != receiver:
    raise newException(ValueError, "IPC selector target already has a receiver")
  endpoint.receiver = receiver
  endpoint.allowed.incl($selector.name)
  router.selectors[target] = endpoint

proc registerProtocol*(
    router: IpcRouter,
    target: string,
    receiver: DynamicAgent,
    protocol: SigilProtocol,
) =
  ## Expose only the selectors declared by a conforming runtime protocol.
  if router.isNil or receiver.isNil:
    raise newException(ValueError, "IPC protocol registration must not be nil")
  if target.len == 0:
    raise newException(ValueError, "IPC protocol target must not be empty")
  if not receiver.conformsTo(protocol):
    raise newException(
      ProtocolConformanceError,
      "receiver does not conform to protocol " & $protocol.name,
    )

  var endpoint = router.selectors.getOrDefault(target)
  if not endpoint.receiver.isNil and endpoint.receiver != receiver:
    raise newException(ValueError, "IPC selector target already has a receiver")
  endpoint.receiver = receiver
  for requirement in protocol.requirements:
    endpoint.allowed.incl($requirement.selector)
  router.selectors[target] = endpoint

proc registerSignal*(
    router: IpcRouter,
    target: string,
    source: Agent,
    name: SigilName,
) =
  ## Allow one incoming notification to be emitted through a local signal.
  if router.isNil or source.isNil:
    raise newException(ValueError, "IPC signal registration must not be nil")
  if target.len == 0:
    raise newException(ValueError, "IPC signal target must not be empty")
  if ($name).len == 0:
    raise newException(ValueError, "IPC signal name must not be empty")
  var endpoint = router.signals.getOrDefault(target)
  if not endpoint.source.isNil and endpoint.source != source:
    raise newException(ValueError, "IPC signal target already has a source")
  endpoint.source = source
  endpoint.allowed.incl($name)
  router.signals[target] = endpoint

proc registerSignalProtocol*(
    router: IpcRouter,
    target: string,
    source: Agent,
    protocol: SigilProtocol,
) =
  ## Allow incoming notifications for the signals declared by a protocol.
  if router.isNil or source.isNil:
    raise newException(ValueError, "IPC signal registration must not be nil")
  if target.len == 0:
    raise newException(ValueError, "IPC signal target must not be empty")
  var endpoint = router.signals.getOrDefault(target)
  if not endpoint.source.isNil and endpoint.source != source:
    raise newException(ValueError, "IPC signal target already has a source")
  endpoint.source = source
  for signal in protocol.signals:
    endpoint.allowed.incl($signal.name)
  router.signals[target] = endpoint

proc handleRequest*(router: IpcRouter, envelope: IpcEnvelope): IpcEnvelope =
  ## Dispatch a request to a slot or selector and produce its response.
  if router.isNil:
    raise routeError(IpcMethodNotFound, "peer has no IPC router")
  validateIpcName(envelope.name)

  let slotKey = (envelope.target, envelope.name)
  if router.slots.hasKey(slotKey):
    let route = router.slots[slotKey]
    let request = SigilRequest(
      kind: Request,
      origin: SigilId(envelope.id),
      procName: toSigilName(envelope.name),
      params: paramsFromPayload(envelope.payload),
    )
    try:
      discard route.receiver.callMethod(request, route.implementation)
    except SigilIpcDecodeError as error:
      raise routeError(IpcInvalidParams, error.msg)
    return responseEnvelope(envelope.id, packIpcPayload(true))

  if not router.selectors.hasKey(envelope.target):
    raise routeError(IpcMethodNotFound, "unknown IPC target: " &
        envelope.target)
  let endpoint = router.selectors[envelope.target]
  if envelope.name notin endpoint.allowed:
    raise routeError(IpcMethodNotFound, "selector is not exposed: " & envelope.name)

  var invocation = Invocation(
    selector: toSigilName(envelope.name),
    params: paramsFromPayload(envelope.payload),
  )
  try:
    if not endpoint.receiver.dispatch(invocation):
      raise routeError(IpcMethodNotFound, "selector was not handled: " & envelope.name)
  except SigilIpcDecodeError as error:
    raise routeError(IpcInvalidParams, error.msg)
  responseEnvelope(envelope.id, payloadFromParams(invocation.result))

proc handleNotify*(router: IpcRouter, envelope: IpcEnvelope) =
  ## Emit an incoming notification through a registered local signal source.
  if router.isNil or not router.signals.hasKey(envelope.target):
    raise routeError(IpcMethodNotFound, "unknown IPC signal target: " &
        envelope.target)
  validateIpcName(envelope.name)
  let endpoint = router.signals[envelope.target]
  if envelope.name notin endpoint.allowed:
    raise routeError(IpcMethodNotFound, "signal is not exposed: " & envelope.name)

  let request = SigilRequest(
    kind: Notify,
    origin: SigilId(-1),
    procName: toSigilName(envelope.name),
    params: paramsFromPayload(envelope.payload),
  )
  endpoint.source.callSlots(request)
