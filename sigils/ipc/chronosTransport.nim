## Bidirectional Sigils RPC peers over Chronos stream transports.

import std/[tables]

import chronos

import ../selectors
import framing
import protocol
import router

type
  IpcConnectionError* = object of CatchableError ## A peer closed or its I/O failed.

  IpcRemoteError* = object of CatchableError ## A structured remote error.
    code*: int32                             ## Structured remote error code.

  IpcPeer* = ref object ## Bidirectional RPC over a Chronos stream.
    transport: StreamTransport
    router: IpcRouter
    maxFrameSize: int
    nextId: uint64
    pending: Table[uint64, Future[IpcEnvelope]]
    reader: Future[void].Raising([])

  IpcServer* = ref object ## Chronos server that owns connected IPC peers.
    transport: StreamServer
    router: IpcRouter
    maxFrameSize: int
    peers: seq[IpcPeer]

proc newIpcPeer(
    transport: StreamTransport,
    router: IpcRouter,
    maxFrameSize: int,
): IpcPeer =
  IpcPeer(
    transport: transport,
    router: router,
    maxFrameSize: maxFrameSize,
    pending: initTable[uint64, Future[IpcEnvelope]](),
  )

proc failPending(peer: IpcPeer, message: string) =
  for future in peer.pending.values:
    if not future.finished():
      future.fail(newException(IpcConnectionError, message))
  peer.pending.clear()

proc sendEnvelope(peer: IpcPeer, envelope: IpcEnvelope) {.async.} =
  await peer.transport.writeFrame(envelope.encodeEnvelope(), peer.maxFrameSize)

proc replyToRequest(peer: IpcPeer, envelope: IpcEnvelope) {.async.} =
  var response: IpcEnvelope
  try:
    {.cast(gcsafe), cast(raises: [CatchableError]).}:
      response = peer.router.handleRequest(envelope)
  except IpcRouteError as error:
    response = errorEnvelope(envelope.id, error.code, error.msg)
  except CatchableError as error:
    response = errorEnvelope(envelope.id, IpcInternalError, error.msg)
  await peer.sendEnvelope(response)

proc readLoop(peer: IpcPeer) {.async: (raises: []).} =
  var closeMessage = "IPC peer closed"
  try:
    while not peer.transport.closed():
      let data = await peer.transport.readFrame(peer.maxFrameSize)
      let envelope = decodeEnvelope(data)
      case envelope.kind
      of IpcResponse, IpcError:
        if peer.pending.hasKey(envelope.id):
          let future = peer.pending[envelope.id]
          if not future.finished():
            future.complete(envelope)
      of IpcRequest:
        await peer.replyToRequest(envelope)
      of IpcNotify:
        {.cast(gcsafe), cast(raises: [CatchableError]).}:
          peer.router.handleNotify(envelope)
  except CancelledError:
    closeMessage = "IPC peer reader cancelled"
  except CatchableError as error:
    closeMessage = error.msg
  finally:
    peer.failPending(closeMessage)
    await peer.transport.closeWait()

proc start(peer: IpcPeer) =
  if peer.reader.isNil:
    peer.reader = peer.readLoop()

proc connectIpc*(
    address: TransportAddress,
    router: IpcRouter = nil,
    maxFrameSize = DefaultIpcMaxFrameSize,
): Future[IpcPeer] {.async.} =
  ## Connect a bidirectional IPC peer over TCP, a Unix socket, or a Windows pipe.
  if maxFrameSize <= 0:
    raise newException(ValueError, "IPC frame size limit must be positive")
  let transport = await connect(address)
  result = newIpcPeer(transport, router, maxFrameSize)
  result.start()

proc callRaw*(
    peer: IpcPeer,
    target: string,
    name: string,
    payload: sink seq[byte],
): Future[seq[byte]] {.async.} =
  ## Send a request and await its correlated response.
  if peer.isNil or peer.transport.closed():
    raise newException(IpcConnectionError, "IPC peer is closed")
  if target.len == 0 or name.len == 0:
    raise newException(ValueError, "IPC target and name must not be empty")

  peer.nextId.inc()
  if peer.nextId == 0:
    peer.nextId.inc()
  let id = peer.nextId
  let responseFuture = newFuture[IpcEnvelope]("sigils.ipc.callRaw")
  peer.pending[id] = responseFuture
  try:
    await peer.sendEnvelope(requestEnvelope(id, target, name, payload))
    let response = await responseFuture
    if response.kind == IpcError:
      let error = newException(IpcRemoteError, response.errorMessage)
      error.code = response.errorCode
      raise error
    result = response.payload
  finally:
    peer.pending.del(id)

proc callSelector*[A, R](
    peer: IpcPeer,
    target: string,
    selector: Selector[A, R],
    args: sink A,
): Future[R] {.async.} =
  ## Invoke a typed selector on a remote dynamic agent.
  let payload = await peer.callRaw(
    target,
    $selector.name,
    packIpcPayload(args),
  )
  result = unpackIpcPayload(payload, R)

proc callSlot*[A](
    peer: IpcPeer,
    target: string,
    name: string,
    args: sink A,
): Future[bool] {.async.} =
  ## Invoke a generated Sigils slot and await its acknowledgement.
  let payload = await peer.callRaw(target, name, packIpcPayload(args))
  result = unpackIpcPayload(payload, bool)

proc notifySignal*[A](
    peer: IpcPeer,
    target: string,
    name: string,
    args: sink A,
) {.async.} =
  ## Send a one-way notification to a registered remote signal endpoint.
  if peer.isNil or peer.transport.closed():
    raise newException(IpcConnectionError, "IPC peer is closed")
  if target.len == 0 or name.len == 0:
    raise newException(ValueError, "IPC target and name must not be empty")
  await peer.sendEnvelope(notifyEnvelope(target, name, packIpcPayload(args)))

proc closed*(peer: IpcPeer): bool =
  ## Return whether a peer is nil or its transport has closed.
  peer.isNil or peer.transport.closed()

proc closeWait*(peer: IpcPeer) {.async: (raises: []).} =
  ## Close a peer and wait for its reader task to finish.
  if peer.isNil:
    return
  await peer.transport.closeWait()
  if not peer.reader.isNil and not peer.reader.finished():
    await noCancel(peer.reader)

proc removePeer(server: IpcServer, peer: IpcPeer) =
  for index, item in server.peers:
    if item == peer:
      server.peers.delete(index)
      return

proc processClient(
    streamServer: StreamServer,
    transport: StreamTransport,
) {.async: (raises: []).} =
  let server = getUserData[IpcServer](streamServer)
  let peer = newIpcPeer(transport, server.router, server.maxFrameSize)
  server.peers.add(peer)
  peer.start()
  await noCancel(peer.reader)
  server.removePeer(peer)

proc createIpcServer*(
    address: TransportAddress,
    router: IpcRouter,
    maxFrameSize = DefaultIpcMaxFrameSize,
): IpcServer =
  ## Bind an IPC server. Call ``start`` after any final route registration.
  if router.isNil:
    raise newException(ValueError, "IPC server router must not be nil")
  if maxFrameSize <= 0:
    raise newException(ValueError, "IPC frame size limit must be positive")
  result = IpcServer(router: router, maxFrameSize: maxFrameSize)
  result.transport = createStreamServer(
    address,
    processClient,
    udata = result,
  )

proc start*(server: IpcServer) =
  ## Start accepting IPC peers.
  server.transport.start()

proc localAddress*(server: IpcServer): TransportAddress =
  ## Return the bound TCP, Unix socket, or named-pipe address.
  server.transport.localAddress()

proc closeWait*(server: IpcServer) {.async: (raises: []).} =
  ## Stop accepting connections and close every active peer.
  if server.isNil:
    return
  try:
    server.transport.stop()
  except CatchableError:
    discard
  await server.transport.closeWait()
  let peers = server.peers
  for peer in peers:
    await peer.closeWait()
  server.peers.setLen(0)
