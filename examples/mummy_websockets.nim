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

type
  ServerEvents {.acyclic.} = ref object of Agent

  ChannelHub {.acyclic.} = ref object of Agent
    clientToChannel: Table[WebSocket, string]
    channels: Table[string, HashSet[WebSocket]]
    heartbeatBuckets: array[30, HashSet[WebSocket]]
    nextBucket: int

  ServerRuntime* = object
    server*: Server
    hubThread*: SigilSelectorThreadPtr
    heartbeatThread*: SigilSelectorThreadPtr
    heartbeatTimer*: SigilTimer
    hubProxy*: AgentProxy[ChannelHub]
    serverEvents*: ServerEvents

proc clientAnnounced*(events: ServerEvents, websocket: WebSocket, channel: string) {.signal.}
proc socketOpened*(events: ServerEvents, websocket: WebSocket) {.signal.}
proc socketClosed*(events: ServerEvents, websocket: WebSocket) {.signal.}

proc setup*(hub: ChannelHub) {.slot.} =
  hub.clientToChannel = initTable[WebSocket, string]()
  hub.channels = initTable[string, HashSet[WebSocket]]()
  hub.heartbeatBuckets = default(array[30, HashSet[WebSocket]])
  hub.nextBucket = 0

proc registerClient*(hub: ChannelHub, websocket: WebSocket, channel: string) {.slot.} =
  hub.clientToChannel[websocket] = channel

proc openClient*(hub: ChannelHub, websocket: WebSocket) {.slot.} =
  let channel = hub.clientToChannel.getOrDefault(websocket, "")
  if channel.len == 0:
    echo "No clientToChannel entry at websocket open"
    return

  var clients = hub.channels.mgetOrPut(channel, initHashSet[WebSocket]())
  clients.incl(websocket)

  let bucket = abs(websocket.hash()) mod hub.heartbeatBuckets.len
  hub.heartbeatBuckets[bucket].incl(websocket)
  hub.nextBucket = bucket

  websocket.send(heartbeatMessage)

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

proc makeUpgradeHandler(events: ServerEvents): RequestHandler =
  result = proc(request: Request) {.gcsafe.} =
    startLocalThreadDefault()
    let channel =
      if request.uri.len > 1: request.uri[1 .. ^1] # Everything after / is the channel name.
      else: ""
    let websocket = request.upgradeToWebSocket()
    emit events.clientAnnounced(websocket, channel)

proc makeWebsocketHandler(events: ServerEvents): WebSocketHandler =
  result = proc(
    websocket: WebSocket,
    event: WebSocketEvent,
    message: Message
  ) {.gcsafe.} =
    startLocalThreadDefault()
    case event:
    of OpenEvent:
      emit events.socketOpened(websocket)

    of MessageEvent:
      if message.kind == Ping:
        websocket.send("", Pong)

    of ErrorEvent:
      discard

    of CloseEvent:
      emit events.socketClosed(websocket)

proc newServerRuntime*(): ServerRuntime =
  startLocalThreadDefault()

  result.hubThread = newSigilSelectorThread()
  var hub = ChannelHub()
  result.hubProxy = hub.moveToThread(result.hubThread)
  result.serverEvents = ServerEvents()

  connectThreaded(result.hubThread.agent, started, result.hubProxy, ChannelHub.setup())
  connectThreaded(result.serverEvents, clientAnnounced, result.hubProxy, ChannelHub.registerClient())
  connectThreaded(result.serverEvents, socketOpened, result.hubProxy, ChannelHub.openClient())
  connectThreaded(result.serverEvents, socketClosed, result.hubProxy, ChannelHub.closeClient())

  result.hubThread.start()

  result.heartbeatThread = newSigilSelectorThread()
  result.heartbeatThread.start()

  result.heartbeatTimer = newSigilTimer(initDuration(seconds = 1))
  connectThreaded(result.heartbeatTimer, timeout, result.hubProxy, ChannelHub.sendHeartbeat())
  start(result.heartbeatTimer, result.heartbeatThread)

  let upgradeHandler = makeUpgradeHandler(result.serverEvents)
  let websocketHandler = makeWebsocketHandler(result.serverEvents)

  var router: Router
  router.get("/*", upgradeHandler)

  result.server = newServer(
    router,
    websocketHandler,
    workerThreads = workerThreads
  )

proc shutdown*(runtime: var ServerRuntime) =
  if runtime.heartbeatTimer != nil and runtime.heartbeatThread != nil:
    cancel(runtime.heartbeatTimer, runtime.heartbeatThread)

  if runtime.heartbeatThread != nil:
    runtime.heartbeatThread.stop()
    runtime.heartbeatThread.join()

  if runtime.hubThread != nil:
    runtime.hubThread.stop()
    runtime.hubThread.join()

proc main() =
  var runtime = newServerRuntime()
  echo "Serving on localhost port ", port
  runtime.server.serve(Port(port))
  runtime.shutdown()

when isMainModule:
  main()
