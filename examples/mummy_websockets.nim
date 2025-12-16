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
  port* = 8123 # The HTTP port to listen on.
  heartbeatMessage* = """{"type":"heartbeat"}""" # The JSON heartbeat message.

var
  channelHubThr* = newSigilSelectorThread()
  heartbeatThr* = newSigilSelectorThread()

var
  lock: Lock # The lock for global memory, just one lock is fine.
  clientToChannel: Table[WebSocket, string] # Store what channel this websocket is subscribed to.

initLock(lock)
channelHubThr.start()
heartbeatThr.start()

proc findChannelName*(ws: WebSocket): string =
  withLock(lock):
    result = clientToChannel.getOrDefault(ws, "")

## ====================== HeartBeat ====================== ##
type
  HeartBeats {.acyclic.} = ref object of Agent
    buckets: array[30, HashSet[WebSocket]]
    timer: SigilTimer

proc add*(heartbeats: AgentProxy[HeartBeats], websocket: WebSocket) {.signal.}
proc remove*(heartbeats: HeartBeats, websocket: WebSocket) {.signal.}

proc toBucketId*(hb: HeartBeats, websocket: WebSocket): int =
  result = abs(websocket.hash()) mod hb.buckets.len()

proc start*(self: HeartBeats) {.slot.} =
  self.timer = newSigilTimer(initDuration(seconds = 1))

proc sendHeartbeats*(hb: HeartBeats, bucket: int) {.slot.} =
  for websocket in hb.buckets[bucket]:
    websocket.send(heartbeatMessage)

## ====================== Channels ====================== ##
type
  Channel = ref object of Agent
    name: string
    clients: HashSet[WebSocket]
    thr: SigilSelectorThreadPtr

proc joining*(channel: Channel, websocket: WebSocket) {.signal.}
proc leaving*(channel: AgentProxy[Channel], websocket: WebSocket) {.signal.}

proc publish*(channel: AgentProxy[Channel], message: Message) {.signal.}

proc toSigName*(name: string): SigilName =
  result = toSigilName("channel:" & name)

proc joined*(self: Channel, websocket: WebSocket) {.slot.} =
  self.clients.incl(websocket)

proc send*(self: Channel, message: Message) {.slot.} =
  for websocket in self.clients:
    websocket.send(message.data, message.kind)

proc websocketHandler(websocket: WebSocket, event: WebSocketEvent, message: Message) =
  startLocalThreadDefault()

  case event:
  of OpenEvent:
    let heartbeats = lookupAgentProxy(sn"HeatBeats", HeartBeats)
    if heartbeats != nil:
      emit heartbeats.add(websocket)

  of MessageEvent:
    let name = websocket.findChannelName()
    if name == "":
      echo "No clientToChannel entry at websocket open"
    else:
      let channel = lookupAgentProxy(name.toSigilName, Channel)
      emit channel.publish(message)

  of ErrorEvent:
    discard

  of CloseEvent:
    let name = websocket.findChannelName()
    if name == "":
      echo "No clientToChannel entry at websocket open"
    else:
      let channel = lookupAgentProxy(name.toSigilName, Channel)
      emit channel.leaving(websocket)

proc findChannelOrCreate(name: string): AgentProxy[Channel] =
  let cn = name.toSigName()
  result = lookupAgentProxy(cn, Channel)
  if result.isNil:
    let thr = newSigilSelectorThread()
    thr.start()
    var channel = Channel(name: name, thr: thr)
    registerGlobalName(cn, channel.moveToThread(thr))

proc upgradeHandler(request: Request) =

  let channelName =
    if request.uri.len > 1: request.uri[1 .. ^1] # Everything after / is the channel name.
    else: ""

  let websocket = request.upgradeToWebSocket()
  let channel = findChannelOrCreate(channelName)
  emit channel.joining(websocket)

## ====================== Main Setup ====================== ##

proc main() =
  echo "Serving on localhost port ", port

  var router: Router
  router.get("/*", upgradeHandler)

  let server = newServer(
    router,
    websocketHandler,
    workerThreads = workerThreads
  )

  server.serve(Port(port))

when isMainModule:
  main()
