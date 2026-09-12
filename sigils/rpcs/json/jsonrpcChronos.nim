## Newline-delimited JSON-RPC on a helper ``SigilChronosThread``.

import std/tables

import chronos

import ../../[core, threadBase, threadChronos]
import jsonrpcAgents

export jsonrpcAgents

const DefaultJsonRpcChronosMaxMessageSize * = 1024 * 1024

type JsonRpcChronosIo = ref object of JsonRpcIoAgent
  host: string
  port: Port
  maxMessageSize: int
  server: StreamServer
  clients: Table[uint64, StreamTransport]
  nextConnectionId: uint64
  running: bool
  stopping: bool

proc removeClient(self: JsonRpcChronosIo, connectionId: uint64) =
  self.clients.del(connectionId)

proc processClient(
    server: StreamServer,
    transport: StreamTransport,
) {.async: (raises: []).} =
  let self = getUserData[JsonRpcChronosIo](server)
  self.nextConnectionId.inc()
  if self.nextConnectionId == 0:
    self.nextConnectionId.inc()
  let connectionId = self.nextConnectionId
  self.clients[connectionId] = transport

  try:
    while not transport.closed():
      var frame = await transport.readLine(
        limit = self.maxMessageSize + 1,
        sep = "\n",
      )
      if frame.len == 0 and transport.atEof():
        break
      if frame.len > self.maxMessageSize:
        break
      if frame.len > 0 and frame[^1] == '\r':
        frame.setLen(frame.len - 1)
      {.cast(gcsafe), cast(raises: [CatchableError]).}:
        emit self.jsonRpcRequestReceived(JsonRpcRequest(
          connectionId: connectionId,
          data: move(frame),
        ))
  except CancelledError:
    discard
  except CatchableError:
    discard
  finally:
    self.removeClient(connectionId)
    await transport.closeWait()

proc writeResponse(
    transport: StreamTransport,
    data: sink string,
) {.async: (raises: []).} =
  try:
    discard await transport.write(data & "\n")
  except CancelledError:
    discard
  except CatchableError:
    await transport.closeWait()

proc stopServer(self: JsonRpcChronosIo) {.async: (raises: []).} =
  try:
    self.server.stop()
  except CatchableError:
    discard
  await self.server.closeWait()

  var clients = newSeqOfCap[StreamTransport](self.clients.len)
  for transport in self.clients.values:
    clients.add(transport)
  for transport in clients:
    await transport.closeWait()
  self.clients.clear()
  self.stopping = false
  try:
    {.cast(gcsafe), cast(raises: [CatchableError]).}:
      emit self.jsonRpcStopped()
  except CatchableError:
    discard

method startIo*(self: JsonRpcChronosIo) {.gcsafe.} =
  if self.running:
    return
  if self.stopping:
    raise newException(ValueError, "Chronos JSON-RPC I/O is stopping")
  if not (getCurrentSigilThread() of SigilChronosThreadPtr):
    raise newException(
      ValueError,
      "Chronos JSON-RPC I/O requires a SigilChronosThread",
    )
  let address = initTAddress(self.host, self.port)
  self.clients = initTable[uint64, StreamTransport]()
  self.server = createStreamServer(
    address,
    processClient,
    flags = {ServerFlags.ReuseAddr},
    udata = self,
  )
  self.server.start()
  self.running = true
  {.cast(gcsafe).}:
    emit self.jsonRpcStarted($self.server.localAddress())

method stopIo*(self: JsonRpcChronosIo) {.gcsafe.} =
  if self.running and not self.stopping:
    self.running = false
    self.stopping = true
    asyncSpawn self.stopServer()

method queueResponse*(
    self: JsonRpcChronosIo,
    response: sink JsonRpcResponse,
) {.gcsafe.} =
  if response.data.len + 1 > self.maxMessageSize:
    return
  if self.clients.hasKey(response.connectionId):
    let transport = self.clients[response.connectionId]
    asyncSpawn transport.writeResponse(response.data)

proc newJsonRpcChronosIo*(
    host = "127.0.0.1",
    port = Port(0),
    maxMessageSize = DefaultJsonRpcChronosMaxMessageSize,
): JsonRpcIoAgent =
  ## Create Chronos-backed JSON-RPC I/O to move onto a Chronos helper thread.
  if host.len == 0:
    raise newException(ValueError, "JSON-RPC host must not be empty")
  if maxMessageSize <= 0:
    raise newException(ValueError, "JSON-RPC message size limit must be positive")
  JsonRpcChronosIo(
    host: host,
    port: port,
    maxMessageSize: maxMessageSize,
  )
