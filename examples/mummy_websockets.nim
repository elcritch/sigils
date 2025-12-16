import mummy, mummy/routers, std/hashes, std/sets, std/tables, std/times,
    ../sigils, ../sigils/threadSelectors

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

## ====================== HeartBeat ====================== ##
type
  HeartBeats {.acyclic.} = ref object of Agent
    buckets: array[30, HashSet[WebSocket]]

proc toBucketId*(hb: HeartBeats, websocket: WebSocket): int =
  result = abs(websocket.hash()) mod hb.buckets.len()

proc start*(hb: HeartBeats) {.slot.} =
  hub.heartbeatTimer = newSigilTimer(initDuration(seconds = 1))

proc sendHeartbeats*(hb: HeartBeats, bucket: int) {.slot.} =
  for websocket in hb.buckets[bucket]:
    websocket.send(heartbeatMessage)

## ====================== Channels ====================== ##
type
  Channel = ref object of Agent
    name: string
    clients: HashSet[WebSocket]
    thr: SigilSelectorThreadPtr

proc joined*(channel: ChannelHub, websocket: WebSocket) {.signal.}

proc toSigName*(name: string): SignalName =
  result = toSigilName("channel:" & name)

proc join*(self: Channel, websocket: WebSocket) {.slot.} =
  self.clients.incl(websocket)

proc publish*(clients: Channel, message: Message) {.slot.} =
  for websocket in self.clients:
    websocket.send(message.data, message.kind)

proc websocketHandler(websocket: WebSocket, event: WebSocketEvent, message: Message) =
  startLocalThreadDefault()

  case event:
  of OpenEvent:
    emit heartbeats.join(websocket)

  of MessageEvent:
    emit channelP.publish(message)

  of ErrorEvent:
    discard

  of CloseEvent:
    emit events.closed(websocket)

proc findChannelOrCreate(name: string): AgentProxy[Channel] =
  let cn = name.toSigName()
  result = lookupAgentProxy(cn, Channel)
  if result.isNil:
    let thr = newSigilSelectorThread()
    thr.start()
    var channel = Channel(name: name, thr: thr)
    registerGlobalName(cn, thr.moveToThread(channel))

proc upgradeHandler(request: Request) =
  let clientHub = lookupAgentProxy(sn"ChannelHub", ChannelHub)

  let channelName =
    if request.uri.len > 1: request.uri[1 .. ^1] # Everything after / is the channel name.
    else: ""

  let websocket = request.upgradeToWebSocket()
  let channel = findChannelOrCreate(channelName)
  emit channel.joined(websocket)

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
