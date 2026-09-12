## Newline-delimited JSON-RPC over a Sigils selector scheduler.

import std/[net, nativesockets, os, selectors, strutils, tables]

import ../../[agents, core, threadBase, threadSelectors]
import jsonrpcAgents

export jsonrpcAgents

const
  DefaultJsonRpcMaxMessageSize* = 1024 * 1024
  JsonRpcReadSize = 16 * 1024

type
  JsonRpcSelectorClient = ref object
    id: uint64
    socket: Socket
    event: SigilSocketEvent
    input, output: string

  JsonRpcSelectorIo = ref object of JsonRpcIoAgent
    host: string
    port: Port
    maxMessageSize: int
    thread: SigilSelectorThreadPtr
    listener: Socket
    listenerEvent: SigilSocketEvent
    clients: Table[int, JsonRpcSelectorClient]
    nextConnectionId: uint64
    running: bool

proc selectorSocketReady(
    self: JsonRpcSelectorIo, fd: int, events: set[Event]
) {.slot.}

proc wouldBlock(error: int32): bool =
  when defined(windows):
    error.int32 == WSAEWOULDBLOCK
  else:
    error.int32 == EAGAIN or error.int32 == EWOULDBLOCK

proc boundAddress(self: JsonRpcSelectorIo): string =
  let (host, port) = self.listener.getLocalAddr()
  host & ":" & $port.uint16

proc closeClient(self: JsonRpcSelectorIo, fd: int) =
  if not self.clients.hasKey(fd):
    return
  let client = self.clients[fd]
  client.event.unregister(self.thread)
  client.socket.close()
  self.clients.del(fd)

proc updateClientEvents(self: JsonRpcSelectorIo,
    client: JsonRpcSelectorClient) =
  let events =
    if client.output.len == 0:
      {Event.Read}
    else:
      {Event.Read, Event.Write}
  if client.event.events != events:
    client.event.setEvents(self.thread, events)

proc flushClient(self: JsonRpcSelectorIo, client: JsonRpcSelectorClient) =
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

proc acceptClient(self: JsonRpcSelectorIo) =
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
    client = JsonRpcSelectorClient(
      id: self.nextConnectionId,
      socket: socket,
      event: event,
    )
  self.clients[fd] = client
  connect(event, socketReady, self, selectorSocketReady)

proc processFrames(self: JsonRpcSelectorIo, client: JsonRpcSelectorClient) =
  var newline = client.input.find('\n')
  while newline >= 0:
    if newline > self.maxMessageSize:
      self.closeClient(client.event.fd)
      return
    var frame = client.input[0..<newline]
    if newline == client.input.high:
      client.input.setLen(0)
    else:
      client.input = client.input[newline + 1..^1]
    if frame.endsWith("\r"):
      frame.setLen(frame.len - 1)
    emit self.jsonRpcRequestReceived(JsonRpcRequest(
      connectionId: client.id,
      data: move(frame),
    ))
    newline = client.input.find('\n')

  if client.input.len > self.maxMessageSize:
    self.closeClient(client.event.fd)

proc readClient(self: JsonRpcSelectorIo, client: JsonRpcSelectorClient) =
  var chunk = newString(JsonRpcReadSize)
  let count = client.socket.recv(addr chunk[0], chunk.len)
  if count == 0:
    self.closeClient(client.event.fd)
  elif count < 0:
    if not wouldBlock(osLastError().int32):
      self.closeClient(client.event.fd)
  else:
    chunk.setLen(count)
    client.input.add(chunk)
    self.processFrames(client)

proc selectorSocketReady(
    self: JsonRpcSelectorIo, fd: int, events: set[Event]
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

method startIo*(self: JsonRpcSelectorIo) {.gcsafe.} =
  if self.running:
    return
  let current = getCurrentSigilThread()
  if not (current of SigilSelectorThreadPtr):
    raise newException(
      ValueError,
      "selector JSON-RPC I/O requires a SigilSelectorThread",
    )
  self.thread = SigilSelectorThreadPtr(current)
  self.clients = initTable[int, JsonRpcSelectorClient]()
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
  emit self.jsonRpcStarted(self.boundAddress())

method stopIo*(self: JsonRpcSelectorIo) {.gcsafe.} =
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
  emit self.jsonRpcStopped()

method queueResponse*(
    self: JsonRpcSelectorIo, response: sink JsonRpcResponse
) {.gcsafe.} =
  var fd = -1
  for candidateFd, client in self.clients.pairs:
    if client.id == response.connectionId:
      fd = candidateFd
      break
  if fd < 0:
    return

  let client = self.clients[fd]
  if client.output.len + response.data.len + 1 > self.maxMessageSize:
    self.closeClient(fd)
  else:
    client.output.add(response.data)
    client.output.add('\n')
    self.flushClient(client)

proc newJsonRpcSelectorIo*(
    host = "127.0.0.1",
    port = Port(0),
    maxMessageSize = DefaultJsonRpcMaxMessageSize,
): JsonRpcIoAgent =
  ## Create selector-backed JSON-RPC I/O; call it only on its owning scheduler.
  if host.len == 0:
    raise newException(ValueError, "JSON-RPC host must not be empty")
  if maxMessageSize <= 0:
    raise newException(ValueError, "JSON-RPC message size limit must be positive")
  JsonRpcSelectorIo(
    host: host,
    port: port,
    maxMessageSize: maxMessageSize,
  )
