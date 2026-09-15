## JSON-RPC 2.0 adaptation for explicitly registered Sigils endpoints.

import std/[json, jsonutils, macros, options, strutils, tables]

import ../[agents, core, selectors]
import router

export json, options, router

const
  JsonRpcVersion* = "2.0"
  JsonRpcParseError* = -32700'i32
  JsonRpcExactSelectorTargetPrefix = "\x00sigils.jsonrpc.selector."
  JsonRpcExactSlotTargetPrefix = "\x00sigils.jsonrpc.slot."
  JsonRpcExactSignalTargetPrefix = "\x00sigils.jsonrpc.signal."

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

proc newJsonRpcAdapter*(): JsonRpcAdapter =
  ## Create a JSON-RPC adapter with its own JSON-specific route codecs.
  JsonRpcAdapter(
    rpcRouter: newRpcRouter(),
    routes: initTable[string, JsonRpcRoute](),
  )

proc router*(adapter: JsonRpcAdapter): RpcRouter =
  ## Return the transport-independent router used by this adapter.
  if adapter.isNil:
    return nil
  adapter.rpcRouter

proc validateJsonRpcMethodName(methodName: string): string =
  if methodName.len == 0:
    raise newException(ValueError, "JSON-RPC method name must not be empty")
  if methodName.startsWith("rpc."):
    raise newException(
      ValueError,
      "JSON-RPC method names beginning with rpc. are reserved",
    )
  methodName

proc jsonRpcMethodName*(target, name: string): string =
  ## Compose the public JSON-RPC method name for a target and Sigils name.
  if target.len == 0 or name.len == 0:
    raise newException(ValueError, "JSON-RPC target and name must not be empty")
  result = validateJsonRpcMethodName(target & "." & name)

proc jsonRpcMethodName*(methodName: string): string =
  ## Validate a JSON-RPC method name without adding a Sigils target prefix.
  validateJsonRpcMethodName(methodName)

proc exactSelectorTarget(methodName: string): string =
  JsonRpcExactSelectorTargetPrefix & methodName

proc exactSlotTarget(methodName: string): string =
  JsonRpcExactSlotTargetPrefix & methodName

proc exactSignalTarget(methodName: string): string =
  JsonRpcExactSignalTargetPrefix & methodName

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

# jsonutils rejects procedure fields with a compile-time AssertionDefect. Keep
# that probe inside the JSON adapter so local and CBOR-only selectors never
# instantiate jsonutils.
proc containsProcedureType(
    node: NimNode, seen: var seq[string], depth = 0
): bool {.compileTime.} =
  if depth >= 64:
    return

  if node.kind == nnkProcTy or node.kind == nnkIteratorTy:
    return true

  if node.kind == nnkSym:
    if node.symKind notin {nskGenericParam, nskType}:
      return
    let signature = node.signatureHash()
    for visited in seen:
      if visited == signature:
        return
    seen.add(signature)

    let implementation = node.getTypeImpl()
    if implementation != node:
      return implementation.containsProcedureType(seen, depth + 1)
    return

  for child in node:
    if child.containsProcedureType(seen, depth + 1):
      return true

macro containsProcedureType(value: typed): untyped =
  var seen: seq[string]
  newLit(value.getTypeInst().containsProcedureType(seen))

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

proc decodeJsonParams[T](data: string): SigilParams =
  var value: T
  when not containsProcedureType(value):
    when compiles(jsonTo(parseJson("null"), T)):
      try:
        let node = parseJson(data)
        when T is tuple:
          value = unpackJsonTuple[T](node)
        else:
          value = jsonTo(node, T)
      except CatchableError as error:
        raise newException(SigilRpcDecodeError, error.msg)
      result = rpcPack(ensureMove(value))
    else:
      raise newException(
        SigilRpcDecodeError,
        "type cannot be decoded from RPC JSON",
      )
  else:
    raise newException(
      SigilRpcDecodeError,
      "type cannot be decoded from RPC JSON",
    )

proc encodeJsonResult[T](params: sink SigilParams): string =
  var value: T
  rpcUnpack(value, params)
  when not containsProcedureType(value):
    when compiles(toJson(value)):
      try:
        result = $toJson(value)
      except CatchableError as error:
        raise newException(SigilRpcEncodeError, error.msg)
    else:
      raise newException(
        SigilRpcEncodeError,
        "type cannot be encoded as RPC JSON",
      )
  else:
    raise newException(
      SigilRpcEncodeError,
      "type cannot be encoded as RPC JSON",
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
  adapter.rpcRouter.registerSelectorRoute(
    target,
    receiver,
    selector.name,
    decodeJsonParams[A],
    encodeJsonResult[R],
  )
  adapter.addRoute(
    methodName,
    target,
    $selector.name,
    JsonRpcMethodKind.Selector,
  )

proc registerSelectorMethod*[A, R](
    adapter: JsonRpcAdapter,
    methodName: string,
    receiver: DynamicAgent,
    selector: Selector[A, R],
) =
  ## Expose one selector under its exact JSON-RPC method name.
  let wireName = jsonRpcMethodName(methodName)
  let target = exactSelectorTarget(wireName)
  adapter.requireAvailable([wireName])
  adapter.rpcRouter.registerSelectorRoute(
    target,
    receiver,
    selector.name,
    decodeJsonParams[A],
    encodeJsonResult[R],
  )
  adapter.addRoute(
    wireName,
    target,
    $selector.name,
    JsonRpcMethodKind.Selector,
  )

proc registerSlot*[A](
    adapter: JsonRpcAdapter,
    target, name: string,
    receiver: Agent,
    implementation: AgentProcTy[A],
) =
  ## Expose one generated slot as ``target.name``.
  let methodName = jsonRpcMethodName(target, name)
  adapter.requireAvailable([methodName])
  adapter.rpcRouter.registerSlotRoute(
    target,
    name,
    receiver,
    implementation,
    decodeJsonParams[A],
    encodeJsonResult[bool],
  )
  adapter.addRoute(methodName, target, name, JsonRpcMethodKind.Slot)

proc registerSlotMethod*[A](
    adapter: JsonRpcAdapter,
    methodName: string,
    receiver: Agent,
    implementation: AgentProcTy[A],
) =
  ## Expose one generated slot under its exact JSON-RPC method name.
  let wireName = jsonRpcMethodName(methodName)
  let target = exactSlotTarget(wireName)
  adapter.requireAvailable([wireName])
  adapter.rpcRouter.registerSlotRoute(
    target,
    wireName,
    receiver,
    implementation,
    decodeJsonParams[A],
    encodeJsonResult[bool],
  )
  adapter.addRoute(
    wireName,
    target,
    wireName,
    JsonRpcMethodKind.Slot,
  )

proc registerSignal*[A](
    adapter: JsonRpcAdapter,
    target: string,
    source: Agent,
    signal: SignalDescriptor[A],
) =
  ## Expose one signal as a JSON-RPC notification named ``target.signal``.
  let methodName = jsonRpcMethodName(target, $signal.name)
  adapter.requireAvailable([methodName])
  adapter.rpcRouter.registerSignalRoute(
    target,
    source,
    signal.name,
    decodeJsonParams[A],
  )
  adapter.addRoute(methodName, target, $signal.name, JsonRpcMethodKind.Signal)

proc registerSignalMethod*[A](
    adapter: JsonRpcAdapter,
    methodName: string,
    source: Agent,
    signal: SignalDescriptor[A],
) =
  ## Expose one signal notification under its exact JSON-RPC method name.
  let wireName = jsonRpcMethodName(methodName)
  let target = exactSignalTarget(wireName)
  adapter.requireAvailable([wireName])
  adapter.rpcRouter.registerSignalRoute(
    target,
    source,
    signal.name,
    decodeJsonParams[A],
  )
  adapter.addRoute(
    wireName,
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

proc isJsonRpcResponseNode(node: JsonNode): bool =
  node.kind == JObject and
    node.hasKey("jsonrpc") and node["jsonrpc"].kind == JString and
    node["jsonrpc"].getStr() == JsonRpcVersion and node.hasKey("id") and
    node["id"].validId() and not node.hasKey("method") and
    ((node.hasKey("result") and not node.hasKey("error")) or
      (node.hasKey("error") and not node.hasKey("result")))

proc isJsonRpcResponse*(data: string): bool =
  ## Return whether encoded data contains a JSON-RPC response message.
  try:
    let root = parseJson(data)
    if root.kind == JObject:
      return root.isJsonRpcResponseNode()
    if root.kind != JArray or root.len == 0:
      return false
    for item in root:
      if not item.isJsonRpcResponseNode():
        return false
    true
  except JsonParsingError:
    false

proc newJsonRpcRequest*(
    id: JsonNode,
    methodName: string,
    params: JsonNode = nil,
): JsonNode =
  ## Build a JSON-RPC request for an outbound server-to-client call.
  if id.isNil or not id.validId():
    raise newException(ValueError, "JSON-RPC request id must be a scalar value")
  result = newJObject()
  result["jsonrpc"] = %JsonRpcVersion
  result["method"] = %jsonRpcMethodName(methodName)
  if not params.isNil:
    if params.kind notin {JArray, JObject}:
      raise newException(ValueError, "JSON-RPC params must be an array or object")
    result["params"] = params
  result["id"] = id

proc newJsonRpcNotification*(
    methodName: string,
    params: JsonNode = nil,
): JsonNode =
  ## Build a JSON-RPC notification for an outbound server-to-client event.
  result = newJObject()
  result["jsonrpc"] = %JsonRpcVersion
  result["method"] = %jsonRpcMethodName(methodName)
  if not params.isNil:
    if params.kind notin {JArray, JObject}:
      raise newException(ValueError, "JSON-RPC params must be an array or object")
    result["params"] = params

proc encodeJsonRpcRequest*(
    id: JsonNode,
    methodName: string,
    params: JsonNode = nil,
): string =
  ## Encode an outbound JSON-RPC request as compact JSON.
  $newJsonRpcRequest(id, methodName, params)

proc encodeJsonRpcNotification*(
    methodName: string,
    params: JsonNode = nil,
): string =
  ## Encode an outbound JSON-RPC notification as compact JSON.
  $newJsonRpcNotification(methodName, params)

proc requestId(node: JsonNode): JsonNode =
  if node.kind == JObject and node.hasKey("id") and node["id"].validId():
    result = node["id"]
  else:
    result = newJNull()

proc handleRequest(adapter: JsonRpcAdapter, node: JsonNode): JsonNode =
  let id = node.requestId()
  if node.kind != JObject:
    return errorNode(RpcInvalidRequest, id)
  if node.isJsonRpcResponseNode():
    # Responses to server-initiated requests are consumed by the dispatcher;
    # they are not requests that should receive another response.
    return nil
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
        $params,
      )
      return nil

    let resultData = adapter.rpcRouter.dispatchRequest(
      route.target,
      route.name,
      $params,
    )
    if notification:
      return nil
    if resultData.len == 0:
      # A void selector/slot is a valid JSON-RPC result. LSP uses this for
      # requests such as ``shutdown``, whose result is JSON null.
      return responseNode(id, newJNull())
    result = responseNode(id, parseJson(resultData))
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
