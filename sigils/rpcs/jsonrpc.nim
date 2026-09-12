## JSON-RPC 2.0 adaptation for runtime Sigils protocols.

import std/[json, options, strutils, tables]

import ../[agents, core, selectors]
import router

export options, router

const
  JsonRpcVersion* = "2.0"
  JsonRpcParseError* = -32700'i32

type
  JsonRpcMethodKind {.pure.} = enum
    Selector
    Slot
    Signal

  JsonRpcRoute = object
    target, name: string
    kind: JsonRpcMethodKind

  JsonRpcAdapter* = ref object
    ## Maps JSON-RPC method names to a transport-independent Sigils RPC router.
    rpcRouter: RpcRouter
    routes: Table[string, JsonRpcRoute]

proc newJsonRpcAdapter*(router: RpcRouter = nil): JsonRpcAdapter =
  ## Create a JSON-RPC adapter, optionally sharing an existing RPC router.
  let resolvedRouter =
    if router.isNil:
      newRpcRouter()
    else:
      router
  JsonRpcAdapter(
    rpcRouter: resolvedRouter,
    routes: initTable[string, JsonRpcRoute](),
  )

proc router*(adapter: JsonRpcAdapter): RpcRouter =
  ## Return the transport-independent router used by this adapter.
  if adapter.isNil:
    return nil
  adapter.rpcRouter

proc jsonRpcMethodName*(target, name: string): string =
  ## Compose the public JSON-RPC method name for a target and Sigils name.
  if target.len == 0 or name.len == 0:
    raise newException(ValueError, "JSON-RPC target and name must not be empty")
  result = target & "." & name
  if result.startsWith("rpc."):
    raise newException(ValueError, "JSON-RPC method names beginning with rpc. are reserved")

proc requireAdapter(adapter: JsonRpcAdapter) =
  if adapter.isNil:
    raise newException(ValueError, "JSON-RPC adapter must not be nil")

proc requireAvailable(adapter: JsonRpcAdapter, methodNames: openArray[string]) =
  adapter.requireAdapter()
  for methodName in methodNames:
    if adapter.routes.hasKey(methodName):
      raise newException(
        ValueError,
        "JSON-RPC method is already registered: " & methodName,
      )

proc addRoute(
    adapter: JsonRpcAdapter,
    methodName, target, name: string,
    kind: JsonRpcMethodKind,
) =
  adapter.routes[methodName] = JsonRpcRoute(
    target: target,
    name: name,
    kind: kind,
  )

proc registerSelector*[A, R](
    adapter: JsonRpcAdapter,
    target: string,
    receiver: DynamicAgent,
    selector: Selector[A, R],
) =
  ## Expose one selector as ``target.selector``.
  let methodName = jsonRpcMethodName(target, $selector.name)
  adapter.requireAvailable([methodName])
  adapter.rpcRouter.registerSelector(target, receiver, selector)
  adapter.addRoute(
    methodName,
    target,
    $selector.name,
    JsonRpcMethodKind.Selector,
  )

proc registerProtocol*(
    adapter: JsonRpcAdapter,
    target: string,
    receiver: DynamicAgent,
    protocol: SigilProtocol,
) =
  ## Expose a conforming protocol's selectors as ``target.selector`` methods.
  var methodNames = newSeqOfCap[string](protocol.requirements.len)
  for requirement in protocol.requirements:
    methodNames.add(jsonRpcMethodName(target, $requirement.selector))
  adapter.requireAvailable(methodNames)
  adapter.rpcRouter.registerProtocol(target, receiver, protocol)
  for index, requirement in protocol.requirements:
    adapter.addRoute(
      methodNames[index],
      target,
      $requirement.selector,
      JsonRpcMethodKind.Selector,
    )

proc registerSlot*(
    adapter: JsonRpcAdapter,
    target, name: string,
    receiver: Agent,
    implementation: AgentProc,
) =
  ## Expose one generated slot as ``target.name``.
  let methodName = jsonRpcMethodName(target, name)
  adapter.requireAvailable([methodName])
  adapter.rpcRouter.registerSlot(target, name, receiver, implementation)
  adapter.addRoute(methodName, target, name, JsonRpcMethodKind.Slot)

proc registerSignal*(
    adapter: JsonRpcAdapter,
    target: string,
    source: Agent,
    name: SigilName,
) =
  ## Expose one signal as a JSON-RPC notification named ``target.signal``.
  let methodName = jsonRpcMethodName(target, $name)
  adapter.requireAvailable([methodName])
  adapter.rpcRouter.registerSignal(target, source, name)
  adapter.addRoute(methodName, target, $name, JsonRpcMethodKind.Signal)

proc registerSignalProtocol*(
    adapter: JsonRpcAdapter,
    target: string,
    source: Agent,
    protocol: SigilProtocol,
) =
  ## Expose a protocol's signals as ``target.signal`` notifications.
  var methodNames = newSeqOfCap[string](protocol.signals.len)
  for signal in protocol.signals:
    methodNames.add(jsonRpcMethodName(target, $signal.name))
  adapter.requireAvailable(methodNames)
  adapter.rpcRouter.registerSignalProtocol(target, source, protocol)
  for index, signal in protocol.signals:
    adapter.addRoute(
      methodNames[index],
      target,
      $signal.name,
      JsonRpcMethodKind.Signal,
    )

proc errorMessage(code: int32): string =
  case code
  of JsonRpcParseError:
    "Parse error"
  of RpcInvalidRequest:
    "Invalid Request"
  of RpcMethodNotFound:
    "Method not found"
  of RpcInvalidParams:
    "Invalid params"
  else:
    "Internal error"

proc responseNode(id, value: JsonNode): JsonNode =
  result = newJObject()
  result["jsonrpc"] = %JsonRpcVersion
  result["result"] = value
  result["id"] = id

proc errorNode(code: int32, id: JsonNode): JsonNode =
  let error = newJObject()
  error["code"] = %code
  error["message"] = %errorMessage(code)
  result = newJObject()
  result["jsonrpc"] = %JsonRpcVersion
  result["error"] = error
  result["id"] = id

proc validId(node: JsonNode): bool =
  node.kind in {JNull, JInt, JFloat, JString}

proc requestId(node: JsonNode): JsonNode =
  if node.kind == JObject and node.hasKey("id") and node["id"].validId():
    result = node["id"]
  else:
    result = newJNull()

proc handleRequest(adapter: JsonRpcAdapter, node: JsonNode): JsonNode =
  let id = node.requestId()
  if node.kind != JObject:
    return errorNode(RpcInvalidRequest, id)
  if not node.hasKey("jsonrpc") or node["jsonrpc"].kind != JString or
      node["jsonrpc"].getStr() != JsonRpcVersion:
    return errorNode(RpcInvalidRequest, id)
  if not node.hasKey("method") or node["method"].kind != JString:
    return errorNode(RpcInvalidRequest, id)
  if node.hasKey("id") and not node["id"].validId():
    return errorNode(RpcInvalidRequest, newJNull())

  let notification = not node.hasKey("id")
  let methodName = node["method"].getStr()
  if methodName.startsWith("rpc.") or not adapter.routes.hasKey(methodName):
    if notification:
      return nil
    return errorNode(RpcMethodNotFound, id)

  let params =
    if node.hasKey("params"):
      node["params"]
    else:
      newJArray()
  if params.kind notin {JArray, JObject}:
    if notification:
      return nil
    return errorNode(RpcInvalidParams, id)

  let route = adapter.routes[methodName]
  try:
    if route.kind == JsonRpcMethodKind.Signal:
      if not notification:
        return errorNode(RpcMethodNotFound, id)
      adapter.rpcRouter.dispatchNotify(
        route.target,
        route.name,
        initRpcParams(RpcWireFormat.Json, $params),
      )
      return nil

    let resultParams = adapter.rpcRouter.dispatchRequest(
      route.target,
      route.name,
      initRpcParams(RpcWireFormat.Json, $params),
    )
    if notification:
      return nil
    if not resultParams.hasRpcData() or
        resultParams.wireFormat != RpcWireFormat.Json:
      return errorNode(RpcInternalError, id)
    result = responseNode(id, parseJson(resultParams.rpcData()))
  except RpcRouteError as error:
    if not notification:
      result = errorNode(error.code, id)
  except CatchableError:
    if not notification:
      result = errorNode(RpcInternalError, id)

proc handleJsonRpc*(
    adapter: JsonRpcAdapter, data: sink string
): Option[string] =
  ## Process one JSON-RPC message or batch and return a response when required.
  adapter.requireAdapter()
  var root: JsonNode
  try:
    root = parseJson(data)
  except JsonParsingError:
    return some($errorNode(JsonRpcParseError, newJNull()))

  if root.kind != JArray:
    let response = adapter.handleRequest(root)
    if response.isNil:
      return none(string)
    return some($response)

  if root.len == 0:
    return some($errorNode(RpcInvalidRequest, newJNull()))

  let responses = newJArray()
  for request in root:
    let response = adapter.handleRequest(request)
    if not response.isNil:
      responses.add(response)
  if responses.len == 0:
    none(string)
  else:
    some($responses)
