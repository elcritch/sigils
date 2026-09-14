## Framed CBOR-RPC on a helper ``SigilChronosThread``.

when not defined(features.sigils.cbor) and
    not defined(features.sigils.ipc):
  {.error: "enable the sigils 'cbor' or 'ipc' package feature before importing CBOR RPC".}

when not defined(features.sigils.chronos):
  {.error: "enable the sigils 'chronos' package feature before importing the Chronos CBOR-RPC transport".}

import std/tables

import chronos

import ../../[core, threadBase, threadChronos]
import crAgents
import crFraming

export crAgents, crFraming

type CborRpcChronosIo = ref object of CborRpcIoAgent
  host: string
  port: Port
  maxFrameSize: int
  server: StreamServer
  clients: Table[uint64, StreamTransport]
  nextConnectionId: uint64
  running: bool
  stopping: bool

proc readFrame(
    transport: StreamTransport,
    maxFrameSize: int,
): Future[string] {.async.} =
  var header: array[7, uint8]
  await transport.readExactly(addr header[0], header.len)
  if header[0] != 0xd8'u8 or header[1] != 0x18'u8 or
      header[2] != 0x5a'u8:
    raise newException(CborRpcFrameError, "unexpected CBOR RPC frame prefix")

  let size =
    (uint32(header[3]) shl 24) or
    (uint32(header[4]) shl 16) or
    (uint32(header[5]) shl 8) or
    uint32(header[6])
  if size == 0:
    raise newException(CborRpcFrameError, "CBOR RPC frames must not be empty")
  if uint64(size) > uint64(maxFrameSize):
    raise newException(
      CborRpcFrameError,
      "CBOR RPC frame exceeds configured size limit",
    )

  result = newString(int(size))
  await transport.readExactly(addr result[0], result.len)

proc removeClient(self: CborRpcChronosIo, connectionId: uint64) =
  self.clients.del(connectionId)

proc processClient(
    server: StreamServer,
    transport: StreamTransport,
) {.async: (raises: []).} =
  let self = getUserData[CborRpcChronosIo](server)
  self.nextConnectionId.inc()
  if self.nextConnectionId == 0:
    self.nextConnectionId.inc()
  let connectionId = self.nextConnectionId
  self.clients[connectionId] = transport

  try:
    while not transport.closed():
      let frame = await transport.readFrame(self.maxFrameSize)
      {.cast(gcsafe), cast(raises: [CatchableError]).}:
        emit self.cborRpcRequestReceived(CborRpcRequest(
          connectionId: connectionId,
          data: frame,
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
    maxFrameSize: int,
) {.async: (raises: []).} =
  try:
    let frame = frameCborRpcPayload(data, maxFrameSize)
    let written = await transport.write(frame)
    if written != frame.len:
      await transport.closeWait()
  except CancelledError:
    discard
  except CatchableError:
    await transport.closeWait()

proc stopServer(self: CborRpcChronosIo) {.async: (raises: []).} =
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
      emit self.cborRpcStopped()
  except CatchableError:
    discard

method startIo*(self: CborRpcChronosIo) {.gcsafe.} =
  if self.running:
    return
  if self.stopping:
    raise newException(ValueError, "Chronos CBOR-RPC I/O is stopping")
  if not (getCurrentSigilThread() of SigilChronosThreadPtr):
    raise newException(
      ValueError,
      "Chronos CBOR-RPC I/O requires a SigilChronosThread",
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
    emit self.cborRpcStarted($self.server.localAddress())

method stopIo*(self: CborRpcChronosIo) {.gcsafe.} =
  if self.running and not self.stopping:
    self.running = false
    self.stopping = true
    asyncSpawn self.stopServer()

method queueResponse*(
    self: CborRpcChronosIo,
    response: sink CborRpcResponse,
) {.gcsafe.} =
  if self.clients.hasKey(response.connectionId):
    let transport = self.clients[response.connectionId]
    asyncSpawn transport.writeResponse(response.data, self.maxFrameSize)

proc newCborRpcChronosIo*(
    host = "127.0.0.1",
    port = Port(0),
    maxFrameSize = DefaultCborRpcMaxFrameSize,
): CborRpcIoAgent =
  ## Create Chronos-backed CBOR-RPC I/O to move onto a Chronos helper thread.
  if host.len == 0:
    raise newException(ValueError, "CBOR-RPC host must not be empty")
  if maxFrameSize <= 0:
    raise newException(ValueError, "CBOR-RPC frame size limit must be positive")
  CborRpcChronosIo(
    host: host,
    port: port,
    maxFrameSize: maxFrameSize,
  )
