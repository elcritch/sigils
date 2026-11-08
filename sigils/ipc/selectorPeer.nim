## Bidirectional CBOR IPC over selector streams.
## The peer and its router must be used on the stream's selector thread.

import std/[options, sets]
import ../[agents, core]
import ../transports/selectorStream
import ../rpcs/cbor/crFraming
import protocol
import router

export selectorStream, protocol, router

type SelectorIpcPeer* = ref object of Agent
  stream: SelectorStream
  router: IpcRouter
  parser: CborRpcFrameParser
  maxFrameSize: int
  nextId: uint64
  pending: HashSet[uint64]
  closed: bool

proc ipcResponse*(peer: SelectorIpcPeer, response: IpcEnvelope) {.signal.}
proc ipcClosed*(peer: SelectorIpcPeer, error: string) {.signal.}
proc ipcRequestFailed*(peer: SelectorIpcPeer, id: uint64,
    error: string) {.signal.}

proc peerData(peer: SelectorIpcPeer, data: string) {.slot.}
proc peerClosed(peer: SelectorIpcPeer, error: string) {.slot.}

proc newSelectorIpcPeer*(stream: SelectorStream, router: IpcRouter = nil,
    maxFrameSize = DefaultCborRpcMaxFrameSize): SelectorIpcPeer =
  ## Attach IPC framing and routing to a connected or connecting stream.
  if stream.isNil or stream.isClosed() or maxFrameSize <= 0:
    raise newException(ValueError, "expected an open stream and positive frame limit")
  result = SelectorIpcPeer(stream: stream, router: router,
    parser: initCborRpcFrameParser(maxFrameSize), maxFrameSize: maxFrameSize,
    pending: initHashSet[uint64]())
  connect(stream, streamData, result, peerData)
  connect(stream, streamClosed, result, peerClosed)

proc send(peer: SelectorIpcPeer, envelope: IpcEnvelope) =
  peer.stream.queueWrite(frameCborRpcPayload(envelope.encodeEnvelope(),
      peer.maxFrameSize))

proc callRaw*(peer: SelectorIpcPeer, target, name: string, payload: sink seq[
    byte]): uint64 =
  ## Queue a request. ipcResponse reports the result with the returned ID.
  if peer.isNil or peer.closed or peer.stream.isClosed():
    raise newException(IOError, "IPC peer is closed")
  if target.len == 0 or name.len == 0:
    raise newException(ValueError, "IPC target and name must not be empty")
  while true:
    peer.nextId = peer.nextId + 1'u64
    if peer.nextId != 0 and peer.nextId notin peer.pending:
      break
  result = peer.nextId
  peer.send(requestEnvelope(result, target, name, payload))
  peer.pending.incl(result)

proc notify*(peer: SelectorIpcPeer, target, name: string, payload: sink seq[byte]) =
  ## Queue a one-way notification.
  if peer.isNil or peer.closed or peer.stream.isClosed():
    raise newException(IOError, "IPC peer is closed")
  if target.len == 0 or name.len == 0:
    raise newException(ValueError, "IPC target and name must not be empty")
  peer.send(notifyEnvelope(target, name, payload))

proc close*(peer: SelectorIpcPeer) =
  if not peer.isNil:
    peer.stream.close()

proc peerClosed(peer: SelectorIpcPeer, error: string) {.slot.} =
  if not peer.closed:
    peer.closed = true
    var pending: seq[uint64]
    for id in peer.pending:
      pending.add(id)
    peer.pending.clear()
    for id in pending:
      emit peer.ipcRequestFailed(id, if error.len ==
          0: "IPC peer closed" else: error)
    emit peer.ipcClosed(error)

proc peerData(peer: SelectorIpcPeer, data: string) {.slot.} =
  try:
    peer.parser.add(data)
    var frame = peer.parser.nextFrame()
    while frame.isSome() and not peer.closed:
      let envelope = decodeEnvelope(frame.get())
      case envelope.kind
      of IpcResponse, IpcError:
        if envelope.id in peer.pending:
          peer.pending.excl(envelope.id)
          emit peer.ipcResponse(envelope)
      of IpcRequest:
        var response: IpcEnvelope
        try:
          response = peer.router.handleRequest(envelope)
        except IpcRouteError as error:
          response = errorEnvelope(envelope.id, error.code, error.msg)
        except CatchableError as error:
          response = errorEnvelope(envelope.id, IpcInternalError, error.msg)
        peer.send(response)
      of IpcNotify:
        peer.router.handleNotify(envelope)
      frame = peer.parser.nextFrame()
  except CatchableError as error:
    peer.stream.abort(error.msg)
