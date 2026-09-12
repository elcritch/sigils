## Sigils agents used to bridge JSON-RPC I/O and protocol dispatch schedulers.

import std/options

import ../../[agents, core, threads]
import ../jsonrpc

export jsonrpc

type
  JsonRpcRequest* = object
    ## One framed request received from a transport connection.
    connectionId*: uint64
    data*: string

  JsonRpcResponse* = object
    ## One framed response destined for a transport connection.
    connectionId*: uint64
    data*: string

  JsonRpcIoAgent* = ref object of AgentActor
    ## Movable base agent for a JSON-RPC transport implementation.

  JsonRpcDispatcher* = ref object of Agent
    ## Application-thread owner of a JSON-RPC adapter.
    adapter*: JsonRpcAdapter
    isListening*: bool
    boundAddress*: string

proc jsonRpcRequestReceived*(
    source: JsonRpcIoAgent, request: JsonRpcRequest
) {.signal.}
proc jsonRpcResponseReady*(
    source: JsonRpcDispatcher, response: JsonRpcResponse
) {.signal.}
proc jsonRpcStartRequested*(source: JsonRpcDispatcher) {.signal.}
proc jsonRpcStopRequested*(source: JsonRpcDispatcher) {.signal.}
proc jsonRpcStarted*(source: JsonRpcIoAgent, address: string) {.signal.}
proc jsonRpcStopped*(source: JsonRpcIoAgent) {.signal.}

method startIo*(self: JsonRpcIoAgent) {.base, gcsafe.} =
  raise newException(AssertionDefect, "JSON-RPC I/O start is not implemented")

method stopIo*(self: JsonRpcIoAgent) {.base, gcsafe.} =
  raise newException(AssertionDefect, "JSON-RPC I/O stop is not implemented")

method queueResponse*(
    self: JsonRpcIoAgent, response: sink JsonRpcResponse
) {.base, gcsafe.} =
  raise newException(AssertionDefect, "JSON-RPC response output is not implemented")

proc startJsonRpcIo*(self: JsonRpcIoAgent) {.slot.} =
  self.startIo()

proc stopJsonRpcIo*(self: JsonRpcIoAgent) {.slot.} =
  self.stopIo()

proc sendJsonRpcResponse*(
    self: JsonRpcIoAgent, response: JsonRpcResponse
) {.slot.} =
  self.queueResponse(response)

proc dispatchJsonRpcRequest*(
    self: JsonRpcDispatcher, request: JsonRpcRequest
) {.slot.} =
  let response = self.adapter.handleJsonRpc(request.data)
  if response.isSome():
    emit self.jsonRpcResponseReady(JsonRpcResponse(
      connectionId: request.connectionId,
      data: response.get(),
    ))

proc recordJsonRpcStarted*(
    self: JsonRpcDispatcher, address: string
) {.slot.} =
  self.boundAddress = address
  self.isListening = true

proc recordJsonRpcStopped*(self: JsonRpcDispatcher) {.slot.} =
  self.isListening = false

proc newJsonRpcDispatcher*(adapter: JsonRpcAdapter): JsonRpcDispatcher =
  ## Create an application-thread dispatcher for an adapter.
  if adapter.isNil:
    raise newException(ValueError, "JSON-RPC adapter must not be nil")
  JsonRpcDispatcher(adapter: adapter)

proc connectJsonRpc*(dispatcher: JsonRpcDispatcher, io: JsonRpcIoAgent) =
  ## Connect locally owned JSON-RPC I/O to its protocol dispatcher.
  if dispatcher.isNil or io.isNil:
    raise newException(ValueError, "JSON-RPC agents must not be nil")
  connect(
    io, jsonRpcRequestReceived,
    dispatcher, JsonRpcDispatcher.dispatchJsonRpcRequest(),
  )
  connect(
    dispatcher, jsonRpcResponseReady,
    io, JsonRpcIoAgent.sendJsonRpcResponse(),
  )
  connect(
    dispatcher, jsonRpcStartRequested,
    io, JsonRpcIoAgent.startJsonRpcIo(),
  )
  connect(
    dispatcher, jsonRpcStopRequested,
    io, JsonRpcIoAgent.stopJsonRpcIo(),
  )
  connect(
    io, jsonRpcStarted,
    dispatcher, JsonRpcDispatcher.recordJsonRpcStarted(),
  )
  connect(
    io, jsonRpcStopped,
    dispatcher, JsonRpcDispatcher.recordJsonRpcStopped(),
  )

proc connectJsonRpc*(
    dispatcher: JsonRpcDispatcher,
    io: AgentProxy[JsonRpcIoAgent],
) =
  ## Connect helper-thread JSON-RPC I/O to its application dispatcher.
  if dispatcher.isNil or io.isNil:
    raise newException(ValueError, "JSON-RPC agents must not be nil")
  connectThreaded(
    io, jsonRpcRequestReceived,
    dispatcher, JsonRpcDispatcher.dispatchJsonRpcRequest(),
  )
  connectThreaded(
    dispatcher, jsonRpcResponseReady,
    io, JsonRpcIoAgent.sendJsonRpcResponse(),
  )
  connectThreaded(
    dispatcher, jsonRpcStartRequested,
    io, JsonRpcIoAgent.startJsonRpcIo(),
  )
  connectThreaded(
    dispatcher, jsonRpcStopRequested,
    io, JsonRpcIoAgent.stopJsonRpcIo(),
  )
  connectThreaded(
    io, jsonRpcStarted,
    dispatcher, JsonRpcDispatcher.recordJsonRpcStarted(),
  )
  connectThreaded(
    io, jsonRpcStopped,
    dispatcher, JsonRpcDispatcher.recordJsonRpcStopped(),
  )
