import mummy, mummy/routers
import std/[hashes, sets, tables, locks, times]

import ../sigils
import ../sigils/[threads, threadSelectors, registry]

## This is a simple websocket server that uses Sigils to manage its heartbeat
## timer on a dedicated selector thread.
##
## WebSocket clients subscribe to a channel based on the url, eg /<channel_name>.
## Those clients will then receive any messages published to <channel_name>.
##
## This server sends a heartbeat message to websocket clients at least every 30
## seconds. This ensures the connection stays open and active in a way websocket
## clients can check (for example, websocket Ping/Pong is not visible to JS).

const
  workerThreads* = 4 # The number of threads handling incoming HTTP requests and websocket messages.
  port* = 8123                                   # The HTTP port to listen on.
  heartbeatMessage* = """{"type":"heartbeat"}""" # The JSON heartbeat message.

var
  channelHubThr* = newSigilSelectorThread()
  heartbeatThr* = newSigilSelectorThread()

var
  lock: Lock # The lock for global memory, just one lock is fine.
  clientToChannel: Table[WebSocket, string] # Store what channel this websocket is subscribed to.

initLock(lock)

proc findChannelName*(ws: WebSocket): string {.gcsafe.} =
  withLock(lock):
    {.cast(gcsafe).}:
      result = clientToChannel.getOrDefault(ws, "")

proc setChannelName*(ws: WebSocket, name: string) {.gcsafe.} =
  withLock(lock):
    {.cast(gcsafe).}:
      clientToChannel[ws] = name

proc removeWebsocket*(ws: WebSocket) {.gcsafe.} =
  withLock(lock):
    {.cast(gcsafe).}:
      clientToChannel.del ws

## ====================== HeartBeat ====================== ##
const HbBuckets = 30
type
  HeartBeats {.acyclic.} = ref object of AgentActor
    count: uint
    buckets: array[HbBuckets, HashSet[WebSocket]]
    timer: SigilTimer

proc doAdd*(heartbeats: Agent, websocket: WebSocket) {.signal.}
proc doRemove*(heartbeats: Agent, websocket: WebSocket) {.signal.}
proc doHeartbeat*(heartbeats: HeartBeats, bucket: int) {.signal.}

proc toBucketId*(websocket: WebSocket): int =
  result = abs(websocket.hash()) mod HbBuckets

proc addClient*(self: HeartBeats, ws: WebSocket) {.slot.} =
  echo "add heartbeat client"
  self.buckets[ws.toBucketId()].incl(ws)

proc removeClient*(self: HeartBeats, ws: WebSocket) {.slot.} =
  echo "remove heartbeat client"
  self.buckets[ws.toBucketId()].excl(ws)

proc sendBucket*(self: HeartBeats, bucket: int) {.slot.} =
  for websocket in self.buckets[bucket]:
    echo "ping: ", websocket
    websocket.send(heartbeatMessage)

  if bucket < self.buckets.len() - 1:
    emit self.doHeartbeat(bucket + 1)

proc runHeartbeat*(self: HeartBeats) {.slot.} =
  echo "Run heartbeat... ", self.count, " (th: ", getThreadId(), ")"
  inc self.count
  self.sendBucket(0)

proc start*(self: HeartBeats) {.slot.} =
  echo "Starting heartbeat!"
  self.timer = newSigilTimer(initDuration(milliseconds = 1_000))
  connect(self.timer, timeout, self, runHeartbeat)
  connect(self, doHeartbeat, self, sendBucket)
  self.timer.start()

proc lookupHeartbeat(): AgentProxy[Heartbeats] =
  result = lookupAgentProxy(sn"HeartBeats", HeartBeats)
  echo "connect heartbeat proxy... "

## ====================== Channels ====================== ##
type
  Channel = ref object of AgentActor
    name: string
    clients: HashSet[WebSocket]
    thr: SigilSelectorThreadPtr

proc joining*(channel: AgentProxy[Channel], websocket: WebSocket) {.signal.}
proc error*(channel: AgentProxy[Channel], websocket: WebSocket,
    message: Message) {.signal.}
proc leaving*(channel: AgentProxy[Channel], websocket: WebSocket) {.signal.}

proc publish*(channel: AgentProxy[Channel], message: Message) {.signal.}

proc toSigName*(name: string): SigilName =
  result = toSigilName("channel:" & name)

proc joined*(self: Channel, websocket: WebSocket) {.slot.} =
  echo "CHANNEL: ", self.name, " Client JOINED: ", websocket
  self.clients.incl(websocket)

proc left*(self: Channel, websocket: WebSocket) {.slot.} =
  echo "CHANNEL: ", self.name, " Client LEFT: ", websocket
  self.clients.excl(websocket)

proc send*(self: Channel, message: Message) {.slot.} =
  for websocket in self.clients:
    websocket.send(message.data, message.kind)

proc findChannelOrCreate*(name: string): AgentProxy[Channel] {.gcsafe.} =
  let cn = name.toSigName()
  if not lookupGlobalName(cn).isSome:
    let thr = newSigilSelectorThread()
    thr.start()
    var channel = Channel(name: name, thr: thr)
    let channelProxy = channel.moveToThread(thr)
    connectThreaded(channelProxy, joining, channelProxy, joined)
    connectThreaded(channelProxy, leaving, channelProxy, left)
    registerGlobalName(cn, channelProxy, cloneSignals = true)

  result = lookupAgentProxy(cn, Channel)
  doAssert result != nil

template withChannel(ws: WebSocket, blk: untyped) =
  let name = ws.findChannelName()
  if name == "":
    echo "Websocket client not in a room! client: ", ws
  else:
    let channel {.inject.} = findChannelOrCreate(name)
    `blk`


proc websocketHandler(websocket: WebSocket, event: WebSocketEvent,
    message: Message) {.gcsafe.} =
  startLocalThreadDefault()

  case event:
  of OpenEvent:
    echo "OpenEvent: ", message
    let heartbeats = lookupHeartbeat()
    if heartbeats != nil:
      emit heartbeats.doAdd(websocket)

  of MessageEvent:
    if message.kind == Ping:
      websocket.send("", Pong)
    elif message.kind == Pong:
      discard
    else:
      echo "MessageEvent: ", message
      withChannel(websocket):
        emit channel.publish(message)

  of ErrorEvent:
    echo "ErrorEvent: ", message
    withChannel(websocket):
      emit channel.error(websocket, message)

  of CloseEvent:
    echo "CloseEvent: ", message
    withChannel(websocket):
      emit channel.leaving(websocket)
    let hb = lookupHeartbeat()
    emit hb.doRemove(websocket)

proc upgradeHandler(request: Request) {.gcsafe.} =

  let channelName =
    if request.uri.len > 1: request.uri[1 .. ^1] # Everything after / is the channel name.
    else: ""

  let websocket = request.upgradeToWebSocket()
  websocket.setChannelName(channelName)
  let channel = findChannelOrCreate(channelName)
  doAssert channel != nil
  emit channel.joining(websocket)

## ====================== Main Setup ====================== ##

proc main() =
  echo "Serving on localhost port ", port

  channelHubThr.start()

  var hbs = HeartBeats()
  let hbsProxy = hbs.moveToThread(heartbeatThr)
  connectThreaded(hbsProxy, doAdd, hbsProxy, addClient)
  connectThreaded(hbsProxy, doRemove, hbsProxy, removeClient)
  connectThreaded(heartbeatThr, started, hbsProxy, start)
  registerGlobalName(sn"HeartBeats", hbsProxy, cloneSignals = true)
  heartbeatThr.start()

  var router: Router
  router.get("/*", upgradeHandler)
  let wsHandler = proc(ws: WebSocket, event: WebSocketEvent,
      message: Message) {.closure, gcsafe.} =
    websocketHandler(ws, event, message)

  let server = newServer(
    router,
    wsHandler,
    workerThreads = workerThreads
  )

  server.serve(Port(port))

when isMainModule:
  main()
