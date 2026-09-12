## Framed CBOR-RPC over a Sigils selector scheduler.

when not defined(features.sigils.cbor) and
    not defined(features.sigils.ipc):
  {.error: "enable the sigils 'cbor' or 'ipc' package feature before importing CBOR RPC".}

import std/[net, nativesockets, options, os, selectors, tables]

import ../../[agents, core, threadBase, threadSelectors]
import crAgents
import crFraming

export crAgents, crFraming

const CborRpcReadSize = 16 * 1024

type
  CborRpcSelectorClient = ref object
    id: uint64
    socket: Socket
    event: SigilSocketEvent
    parser: CborRpcFrameParser
    output: string

  CborRpcSelectorIo = ref object of CborRpcIoAgent
    host: string
    port: Port
    maxFrameSize: int
    thread: SigilSelectorThreadPtr
    listener: Socket
    listenerEvent: SigilSocketEvent
    clients: Table[int, CborRpcSelectorClient]
    nextConnectionId: uint64
    running: bool

proc selectorSocketReady(
    self: CborRpcSelectorIo, fd: int, events: set[Event]
) {.slot.}

proc wouldBlock(error: int32): bool =
  when defined(windows):
    error == WSAEWOULDBLOCK
  else:
    error == EAGAIN or error == EWOULDBLOCK

proc boundAddress(self: CborRpcSelectorIo): string =
  let (host, port) = self.listener.getLocalAddr()
  host & ":" & $port.uint16

proc closeClient(self: CborRpcSelectorIo, fd: int) =
  if not self.clients.hasKey(fd):
    return
  let client = self.clients[fd]
  client.event.unregister(self.thread)
  client.socket.close()
  self.clients.del(fd)

proc updateClientEvents(
    self: CborRpcSelectorIo, client: CborRpcSelectorClient
) =
  let events =
    if client.output.len == 0:
      {Event.Read}
    else:
      {Event.Read, Event.Write}
  if client.event.events != events:
    client.event.setEvents(self.thread, events)

proc flushClient(self: CborRpcSelectorIo, client: CborRpcSelectorClient) =
  if client.output.len == 0:
    self.updateClientEvents(client)
    return

  let written = client.socket.send(
    unsafeAddr client.output[0], client.output.len
  )
  if written > 0:
    if written == client.output.len:
      client.output.setLen(0)
    else:
      client.output = client.output[written..^1]
  elif written < 0 and not wouldBlock(osLastError().int32):
    self.closeClient(client.event.fd)
    return
  self.updateClientEvents(client)

proc acceptClient(self: CborRpcSelectorIo) =
  var socket: owned(Socket)
  try:
    self.listener.accept(socket)
  except OSError as error:
    if wouldBlock(error.errorCode):
      return
    raise

  socket.getFd().setBlocking(false)
  self.nextConnectionId.inc()
  if self.nextConnectionId == 0:
    self.nextConnectionId.inc()
  let
    fd = socket.getFd().int
    event = newSigilSocketEvent(self.thread, fd)
    client = CborRpcSelectorClient(
      id: self.nextConnectionId,
      socket: socket,
      event: event,
      parser: initCborRpcFrameParser(self.maxFrameSize),
    )
  self.clients[fd] = client
  connect(event, socketReady, self, selectorSocketReady)

proc processFrames(self: CborRpcSelectorIo, client: CborRpcSelectorClient) =
  try:
    var frame = client.parser.nextFrame()
    while frame.isSome():
      emit self.cborRpcRequestReceived(CborRpcRequest(
        connectionId: client.id,
        data: frame.get(),
      ))
      frame = client.parser.nextFrame()
  except CborRpcFrameError:
    self.closeClient(client.event.fd)

proc readClient(self: CborRpcSelectorIo, client: CborRpcSelectorClient) =
  var chunk = newString(CborRpcReadSize)
  let count = client.socket.recv(addr chunk[0], chunk.len)
  if count == 0:
    self.closeClient(client.event.fd)
  elif count < 0:
    if not wouldBlock(osLastError().int32):
      self.closeClient(client.event.fd)
  else:
    chunk.setLen(count)
    client.parser.add(chunk)
    self.processFrames(client)

proc selectorSocketReady(
    self: CborRpcSelectorIo, fd: int, events: set[Event]
) {.slot.} =
  if Event.Error in events:
    self.closeClient(fd)
  elif self.listenerEvent != nil and fd == self.listenerEvent.fd:
    if Event.Read in events:
      self.acceptClient()
  elif self.clients.hasKey(fd):
    let client = self.clients[fd]
    if Event.Read in events:
      self.readClient(client)
    if self.clients.hasKey(fd) and Event.Write in events:
      self.flushClient(client)

method startIo*(self: CborRpcSelectorIo) {.gcsafe.} =
  if self.running:
    return
  let current = getCurrentSigilThread()
  if not (current of SigilSelectorThreadPtr):
    raise newException(
      ValueError,
      "selector CBOR-RPC I/O requires a SigilSelectorThread",
    )
  self.thread = SigilSelectorThreadPtr(current)
  self.clients = initTable[int, CborRpcSelectorClient]()
  self.listener = newSocket(
    domain = Domain.AF_INET,
    sockType = SockType.SOCK_STREAM,
    protocol = Protocol.IPPROTO_TCP,
    buffered = false,
  )
  self.listener.setSockOpt(OptReuseAddr, true)
  self.listener.getFd().setBlocking(false)
  self.listener.bindAddr(self.port, self.host)
  self.listener.listen()
  self.listenerEvent = newSigilSocketEvent(self.thread, self.listener)
  connect(self.listenerEvent, socketReady, self, selectorSocketReady)
  self.running = true
  emit self.cborRpcStarted(self.boundAddress())

method stopIo*(self: CborRpcSelectorIo) {.gcsafe.} =
  if not self.running:
    return
  var fds = newSeqOfCap[int](self.clients.len)
  for fd in self.clients.keys:
    fds.add(fd)
  for fd in fds:
    self.closeClient(fd)
  self.listenerEvent.unregister(self.thread)
  self.listener.close()
  self.running = false
  emit self.cborRpcStopped()

method queueResponse*(
    self: CborRpcSelectorIo, response: sink CborRpcResponse
) {.gcsafe.} =
  var fd = -1
  for candidateFd, client in self.clients.pairs:
    if client.id == response.connectionId:
      fd = candidateFd
      break
  if fd < 0:
    return

  let client = self.clients[fd]
  try:
    let frame = frameCborRpcPayload(response.data, self.maxFrameSize)
    if client.output.len + frame.len > self.maxFrameSize:
      self.closeClient(fd)
    else:
      client.output.add(frame)
      self.flushClient(client)
  except CborRpcFrameError:
    self.closeClient(fd)

proc newCborRpcSelectorIo*(
    host = "127.0.0.1",
    port = Port(0),
    maxFrameSize = DefaultCborRpcMaxFrameSize,
): CborRpcIoAgent =
  ## Create selector-backed CBOR-RPC I/O for a local or helper scheduler.
  if host.len == 0:
    raise newException(ValueError, "CBOR-RPC host must not be empty")
  if maxFrameSize <= 0:
    raise newException(ValueError, "CBOR-RPC frame size limit must be positive")
  CborRpcSelectorIo(
    host: host,
    port: port,
    maxFrameSize: maxFrameSize,
  )
