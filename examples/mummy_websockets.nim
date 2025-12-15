import mummy, mummy/routers, std/hashes, std/nativesockets, std/sets, std/tables,
    std/times, ready, sigils, sigils/threadSelectors

## This is a more complex example of using Mummy as a websocket server.
##
## WebSocket clients subscribe to a channel based on the url, eg /<channel_name>.
## Those clients will then receive any messages published to <channel_name>.
##
## Redis is used as the messaging hub so that multiple instances can run and
## messages can be pubished from other servers. To enable this, Redis PubSub
## is used. (Check out the Redis docs on that to learn more.)
##
## This server sends a heartbeat message to websocket clients at least every 30
## seconds. This ensure the connection stays open and active in a way websocket
## clients can check (for example, websocket Ping/Pong is not visible to JS).

const
  workerThreads = 4 # The number of threads handling incoming HTTP requests and websocket messages.
  port = 8123 # The HTTP port to listen on.
  heartbeatMessage = """{"type":"heartbeat"}""" # The JSON heartbeat message.

let pubsubRedis = newRedisConn() # The Redis connection used for PubSub.

type
  # Access the Redis socket so we can register it with the Sigils selector.
  RedisConnHead = object
    socket: SocketHandle

  ServerEvents = ref object of Agent

  ChannelHub = ref object of Agent
    clientToChannel: Table[WebSocket, string]
    channels: Table[string, HashSet[WebSocket]]
    heartbeatBuckets: array[30, HashSet[WebSocket]]
    nextBucket: int
    heartbeatTimer: SigilTimer
    redisReady: SigilSocketEvent

proc clientAnnounced*(events: ServerEvents, websocket: WebSocket, channel: string) {.signal.}
proc socketOpened*(events: ServerEvents, websocket: WebSocket) {.signal.}
proc socketClosed*(events: ServerEvents, websocket: WebSocket) {.signal.}

proc setup*(hub: ChannelHub) {.slot.}
proc registerClient*(hub: ChannelHub, websocket: WebSocket, channel: string) {.slot.}
proc openClient*(hub: ChannelHub, websocket: WebSocket) {.slot.}
proc closeClient*(hub: ChannelHub, websocket: WebSocket) {.slot.}
proc publish*(hub: ChannelHub, channel: string, message: string) {.slot.}
proc sendHeartbeat*(hub: ChannelHub) {.slot.}
proc handleRedisReady*(hub: ChannelHub) {.slot.}

proc redisSocketHandle(conn: RedisConn): SocketHandle =
  ## Ready does not expose the socket handle, but the selector-based Sigil
  ## thread needs it to register a read event. This relies on the current
  ## layout of RedisConnObj in Ready.
  cast[ptr RedisConnHead](conn)[] .socket

proc setup*(hub: ChannelHub) {.slot.} =
  let selectorThread = SigilSelectorThreadPtr(getCurrentSigilThread())

  hub.redisReady = newSigilSocketEvent(selectorThread, redisSocketHandle(pubsubRedis).int)
  connect(hub.redisReady, dataReady, hub, ChannelHub.handleRedisReady())

  hub.heartbeatTimer = newSigilTimer(initDuration(seconds = 1))
  connect(hub.heartbeatTimer, timeout, hub, ChannelHub.sendHeartbeat())
  start(hub.heartbeatTimer, selectorThread)

proc registerClient*(hub: ChannelHub, websocket: WebSocket, channel: string) {.slot.} =
  hub.clientToChannel[websocket] = channel

proc openClient*(hub: ChannelHub, websocket: WebSocket) {.slot.} =
  var needsSubscribe = false
  let channel = hub.clientToChannel.getOrDefault(websocket, "")
  if channel.len == 0:
    echo "No clientToChannel entry at websocket open"
    return

  if channel notin hub.channels:
    hub.channels[channel] = initHashSet[WebSocket]()
    needsSubscribe = true
  hub.channels[channel].incl(websocket)

  let bucket = abs(websocket.hash()) mod hub.heartbeatBuckets.len
  hub.heartbeatBuckets[bucket].incl(websocket)

  websocket.send(heartbeatMessage)

  if needsSubscribe:
    try:
      pubsubRedis.send("SUBSCRIBE", channel)
    except CatchableError:
      echo "Failed to subscribe to channel ", channel, ": ", getCurrentExceptionMsg()

proc closeClient*(hub: ChannelHub, websocket: WebSocket) {.slot.} =
  if websocket notin hub.clientToChannel:
    echo "No clientToChannel entry at websocket close"
    return

  let channel = hub.clientToChannel[websocket]
  hub.clientToChannel.del(websocket)

  if channel in hub.channels:
    hub.channels[channel].excl(websocket)
    let bucket = abs(websocket.hash()) mod hub.heartbeatBuckets.len
    hub.heartbeatBuckets[bucket].excl(websocket)
    if hub.channels[channel].len == 0:
      hub.channels.del(channel)
      try:
        pubsubRedis.send("UNSUBSCRIBE", channel)
      except CatchableError:
        echo "Failed to unsubscribe from channel ", channel, ": ", getCurrentExceptionMsg()
  else:
    echo "No channels entry for channel at websocket close"

proc publish*(hub: ChannelHub, channel: string, message: string) {.slot.} =
  if channel in hub.channels and hub.channels[channel].len > 0:
    for websocket in hub.channels[channel]:
      websocket.send(message, TextMessage)
  else:
    echo "Dropped message to channel without clients"

proc sendHeartbeat*(hub: ChannelHub) {.slot.} =
  let bucket = hub.nextBucket
  for websocket in hub.heartbeatBuckets[bucket]:
    websocket.send(heartbeatMessage)
  hub.nextBucket = (hub.nextBucket + 1) mod hub.heartbeatBuckets.len

proc handleRedisReady*(hub: ChannelHub) {.slot.} =
  try:
    let reply = pubsubRedis.receive()
    let event = reply[0].to(string)
    case event:
    of "subscribe", "unsubscribe":
      discard
    of "message":
      let channel = reply[1].to(string)
      let message = reply[2].to(string)
      hub.publish(channel, message)
    else:
      echo "Unexpected Redis PubSub event: ", event
  except CatchableError:
    echo "Fatal error in Redis handler: ", getCurrentExceptionMsg()
    quit(1)

startLocalThreadDefault()

let sigilThread = newSigilSelectorThread()
var hub = ChannelHub()
let hubProxy: AgentProxy[ChannelHub] = hub.moveToThread(sigilThread)
var serverEvents = ServerEvents()

connectThreaded(sigilThread.agent, started, hubProxy, ChannelHub.setup())
connectThreaded(serverEvents, clientAnnounced, hubProxy, ChannelHub.registerClient())
connectThreaded(serverEvents, socketOpened, hubProxy, ChannelHub.openClient())
connectThreaded(serverEvents, socketClosed, hubProxy, ChannelHub.closeClient())

sigilThread.start()

# This is the HTTP handler for /* requests. These requests are upgraded to websockets.
proc upgradeHandler(request: Request) =
  startLocalThreadDefault()
  let channel = request.uri[1 .. ^1] # Everything after / is the channel name.
  let websocket = request.upgradeToWebSocket()
  emit serverEvents.clientAnnounced(websocket, channel)

# WebSocket events are received by this handler.
proc websocketHandler(
  websocket: WebSocket,
  event: WebSocketEvent,
  message: Message
) =
  startLocalThreadDefault()
  case event:
  of OpenEvent:
    emit serverEvents.socketOpened(websocket)

  of MessageEvent:
    if message.kind == Ping:
      websocket.send("", Pong)

  of ErrorEvent:
    discard

  of CloseEvent:
    emit serverEvents.socketClosed(websocket)

# A simple router sending all requests to be upgraded to websockets.
var router: Router
router.get("/*", upgradeHandler)

let server = newServer(
  router,
  websocketHandler,
  workerThreads = workerThreads
)
echo "Serving on localhost port ", port
server.serve(Port(port))
