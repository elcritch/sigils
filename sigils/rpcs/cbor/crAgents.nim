## Sigils agents bridging CBOR-RPC transports and protocol dispatch schedulers.

when not defined(features.sigils.cbor) and
    not defined(features.sigils.ipc):
  {.error: "enable the sigils 'cbor' or 'ipc' package feature before importing CBOR RPC".}

import std/options

import ../../[agents, core, threads]
import ../cborRpc

export cborRpc

type
  CborRpcRequest* = object
    ## One decoded transport frame received from a connection.
    connectionId*: uint64
    data*: string

  CborRpcResponse* = object
    ## One encoded response destined for a transport connection.
    connectionId*: uint64
    data*: string

  CborRpcIoAgent* = ref object of AgentActor
    ## Movable extension point implemented by CBOR-RPC transports.

  CborRpcDispatcher* = ref object of Agent
    ## Application-thread owner of a CBOR-RPC router.
    router*: CborRpcRouter
    isListening*: bool
    boundAddress*: string

proc cborRpcRequestReceived*(
    source: CborRpcIoAgent, request: CborRpcRequest
) {.signal.}
proc cborRpcResponseReady*(
    source: CborRpcDispatcher, response: CborRpcResponse
) {.signal.}
proc cborRpcStartRequested*(source: CborRpcDispatcher) {.signal.}
proc cborRpcStopRequested*(source: CborRpcDispatcher) {.signal.}
proc cborRpcStarted*(source: CborRpcIoAgent, address: string) {.signal.}
proc cborRpcStopped*(source: CborRpcIoAgent) {.signal.}

method startIo*(self: CborRpcIoAgent) {.base, gcsafe.} =
  raise newException(AssertionDefect, "CBOR-RPC I/O start is not implemented")

method stopIo*(self: CborRpcIoAgent) {.base, gcsafe.} =
  raise newException(AssertionDefect, "CBOR-RPC I/O stop is not implemented")

method queueResponse*(
    self: CborRpcIoAgent, response: sink CborRpcResponse
) {.base, gcsafe.} =
  raise newException(AssertionDefect, "CBOR-RPC response output is not implemented")

proc startCborRpcIo*(self: CborRpcIoAgent) {.slot.} =
  self.startIo()

proc stopCborRpcIo*(self: CborRpcIoAgent) {.slot.} =
  self.stopIo()

proc sendCborRpcResponse*(
    self: CborRpcIoAgent, response: CborRpcResponse
) {.slot.} =
  self.queueResponse(response)

proc dispatchCborRpcRequest*(
    self: CborRpcDispatcher, request: CborRpcRequest
) {.slot.} =
  try:
    let response = self.router.handleCborRpc(request.data)
    if response.isSome():
      emit self.cborRpcResponseReady(CborRpcResponse(
        connectionId: request.connectionId,
        data: response.get(),
      ))
  except CborRpcProtocolError:
    discard

proc recordCborRpcStarted*(
    self: CborRpcDispatcher, address: string
) {.slot.} =
  self.boundAddress = address
  self.isListening = true

proc recordCborRpcStopped*(self: CborRpcDispatcher) {.slot.} =
  self.isListening = false

proc newCborRpcDispatcher*(router: CborRpcRouter): CborRpcDispatcher =
  ## Create an application-thread dispatcher for a CBOR-RPC router.
  if router.isNil:
    raise newException(ValueError, "CBOR-RPC router must not be nil")
  CborRpcDispatcher(router: router)

proc connectCborRpc*(dispatcher: CborRpcDispatcher, io: CborRpcIoAgent) =
  ## Connect locally owned CBOR-RPC I/O to its protocol dispatcher.
  if dispatcher.isNil or io.isNil:
    raise newException(ValueError, "CBOR-RPC agents must not be nil")
  connect(
    io, cborRpcRequestReceived,
    dispatcher, CborRpcDispatcher.dispatchCborRpcRequest(),
  )
  connect(
    dispatcher, cborRpcResponseReady,
    io, CborRpcIoAgent.sendCborRpcResponse(),
  )
  connect(
    dispatcher, cborRpcStartRequested,
    io, CborRpcIoAgent.startCborRpcIo(),
  )
  connect(
    dispatcher, cborRpcStopRequested,
    io, CborRpcIoAgent.stopCborRpcIo(),
  )
  connect(
    io, cborRpcStarted,
    dispatcher, CborRpcDispatcher.recordCborRpcStarted(),
  )
  connect(
    io, cborRpcStopped,
    dispatcher, CborRpcDispatcher.recordCborRpcStopped(),
  )

proc connectCborRpc*(
    dispatcher: CborRpcDispatcher,
    io: AgentProxy[CborRpcIoAgent],
) =
  ## Connect helper-thread CBOR-RPC I/O to its application dispatcher.
  if dispatcher.isNil or io.isNil:
    raise newException(ValueError, "CBOR-RPC agents must not be nil")
  connectThreaded(
    io, cborRpcRequestReceived,
    dispatcher, CborRpcDispatcher.dispatchCborRpcRequest(),
  )
  connectThreaded(
    dispatcher, cborRpcResponseReady,
    io, CborRpcIoAgent.sendCborRpcResponse(),
  )
  connectThreaded(
    dispatcher, cborRpcStartRequested,
    io, CborRpcIoAgent.startCborRpcIo(),
  )
  connectThreaded(
    dispatcher, cborRpcStopRequested,
    io, CborRpcIoAgent.stopCborRpcIo(),
  )
  connectThreaded(
    io, cborRpcStarted,
    dispatcher, CborRpcDispatcher.recordCborRpcStarted(),
  )
  connectThreaded(
    io, cborRpcStopped,
    dispatcher, CborRpcDispatcher.recordCborRpcStopped(),
  )
