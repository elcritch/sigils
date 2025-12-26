import mummy, std/[base64, net, random, sha1, strformat, strutils]
#import ./mummy_websockets
const
  heartbeatMessage* = """{"type":"heartbeat"}""" # The JSON heartbeat message.


const
  testChannel = "/demo"

type
  WsOpcode = enum
    opContinuation = 0x0
    opText = 0x1
    opBinary = 0x2
    opClose = 0x8
    opPing = 0x9
    opPong = 0xA

  WebSocketFrame = object
    fin: bool
    opcode: WsOpcode
    payload: string

  WebSocketClient = object
    socket: Socket
    buffer: string

proc generateKey(): string =
  var raw = newString(16)
  for i in 0 ..< raw.len:
    raw[i] = char(rand(255))
  encode(raw)

proc expectedAccept(key: string): string =
  const websocketGuid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
  let digest = secureHash(key & websocketGuid)
  encode(Sha1Digest(digest))

proc connectWebSocket(host: string, port: int, path: string): WebSocketClient =
  var socket = newSocket(buffered = false)
  socket.connect(host, Port(port))

  let key = generateKey()
  let requestLines = [
    fmt"GET {path} HTTP/1.1",
    fmt"Host: {host}:{port}",
    "Upgrade: websocket",
    "Connection: Upgrade",
    "Sec-WebSocket-Version: 13",
    fmt"Sec-WebSocket-Key: {key}",
    "",
    ""
  ]
  socket.send(requestLines.join("\r\n"))

  var response = ""
  while "\r\n\r\n" notin response:
    let chunk = socket.recv(1, 5000)
    if chunk.len == 0:
      raise newException(IOError, "Socket closed during handshake")
    response.add(chunk)

  let headerEnd = response.find("\r\n\r\n")
  if headerEnd < 0:
    raise newException(IOError, "Incomplete HTTP response during handshake")

  let headerText = response[0 ..< headerEnd]
  let lines = headerText.splitLines()
  if lines.len == 0 or not lines[0].startsWith("HTTP/1.1 101"):
    let status = if lines.len == 0: "missing status line" else: lines[0]
    raise newException(IOError, "Unexpected handshake status: " & status)

  var acceptHeader = ""
  if lines.len > 1:
    for line in lines[1 .. ^1]:
      let parts = line.split(":", 1)
      if parts.len == 2 and parts[0].toLowerAscii() == "sec-websocket-accept":
        acceptHeader = parts[1].strip()
        break

  let expected = expectedAccept(key)
  if acceptHeader.len == 0 or acceptHeader != expected:
    raise newException(IOError,
      "Bad Sec-WebSocket-Accept: " & acceptHeader & " expected " & expected)

  result.socket = socket
  if headerEnd + 4 < response.len:
    result.buffer = response[headerEnd + 4 .. ^1]
  else:
    result.buffer = ""

proc recvExact(client: var WebSocketClient, size: int, timeoutMs = 5000) =
  while client.buffer.len < size:
    let chunk = client.socket.recv(size - client.buffer.len, timeoutMs)
    if chunk.len == 0:
      raise newException(IOError, "Connection closed while receiving frame")
    client.buffer.add(chunk)

proc readFrame*(client: var WebSocketClient, timeoutMs = 5000): WebSocketFrame =
  client.recvExact(2, timeoutMs)
  let first = client.buffer[0].ord
  let second = client.buffer[1].ord
  var offset = 2
  var payloadLen = second and 0x7f
  if payloadLen == 126:
    client.recvExact(offset + 2, timeoutMs)
    payloadLen = (client.buffer[offset].ord shl 8) or client.buffer[offset + 1].ord
    offset += 2
  elif payloadLen == 127:
    client.recvExact(offset + 8, timeoutMs)
    var len64: uint64 = 0
    for i in 0 .. 7:
      len64 = (len64 shl 8) or client.buffer[offset + i].ord.uint64
    payloadLen = int(len64)
    offset += 8
  let masked = (second and 0x80) != 0
  var mask: array[4, byte]
  if masked:
    client.recvExact(offset + 4, timeoutMs)
    for i in 0 .. 3:
      mask[i] = byte(client.buffer[offset + i].ord)
    offset += 4
  client.recvExact(offset + payloadLen, timeoutMs)
  var payload = if payloadLen == 0: "" else: client.buffer[offset ..< offset + payloadLen]
  if masked:
    for i in 0 ..< payload.len:
      payload[i] = char(payload[i].ord xor mask[i mod 4].int)

  var opcode: WsOpcode
  case (first and 0x0f)
  of 0x0:
    opcode = opContinuation
  of 0x1:
    opcode = opText
  of 0x2:
    opcode = opBinary
  of 0x8:
    opcode = opClose
  of 0x9:
    opcode = opPing
  of 0xA:
    opcode = opPong
  else:
    raise newException(IOError, "Unsupported opcode: " & $(first and 0x0f))

  if offset + payloadLen >= client.buffer.len:
    client.buffer.setLen(0)
  else:
    client.buffer = client.buffer[offset + payloadLen .. ^1]
  result = WebSocketFrame(
    fin: (first and 0x80) != 0,
    opcode: opcode,
    payload: payload
  )

proc sendFrame*(client: var WebSocketClient, opcode: WsOpcode, payload: string = "") =
  var header = newString(0)
  header.add(char(0x80 or ord(opcode)))

  let length = payload.len
  if length < 126:
    header.add(char(0x80 or length))
  elif length <= 0xffff:
    header.add(char(0x80 or 126))
    header.add(char((length shr 8) and 0xff))
    header.add(char(length and 0xff))
  else:
    header.add(char(0x80 or 127))
    for shift in countdown(56, 0, 8):
      header.add(char((length shr shift) and 0xff))

  var maskBytes: array[4, byte]
  for i in 0 .. 3:
    maskBytes[i] = byte(rand(255))
    header.add(char(maskBytes[i]))

  var maskedPayload = newString(length)
  for i, ch in payload:
    maskedPayload[i] = char(ch.ord xor maskBytes[i mod 4].int)

  client.socket.send(header & maskedPayload)

proc closeClient(client: var WebSocketClient) =
  try:
    client.sendFrame(opClose)
  except CatchableError:
    discard
  close(client.socket)

proc runClient() =
  let port = 8123
  var client = connectWebSocket("127.0.0.1", port, testChannel)

  let first = client.readFrame()
  doAssert first.opcode == opText
  doAssert first.payload == heartbeatMessage

  let timedHeartbeat = client.readFrame(3000)
  doAssert timedHeartbeat.opcode == opText
  doAssert timedHeartbeat.payload == heartbeatMessage

  client.sendFrame(opPing)
  let pong = client.readFrame(3000)
  doAssert pong.opcode == opPong

  closeClient(client)

proc main() =
  randomize()
  runClient()
  #var runtime = newServerRuntime()
  #var clientThread: Thread[ptr ServerRuntime]
  #createThread(clientThread, runClient, addr runtime)
  #runtime.server.serve(Port(port))
  #joinThread(clientThread)
  #runtime.shutdown()
  GC_fullCollect()

  echo "WebSocket server responded with heartbeats and pong successfully"

when isMainModule:
  main()
