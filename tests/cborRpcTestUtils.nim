import std/[net, parseutils, strutils]

proc splitTcpAddress*(address: string): tuple[host: string, port: Port] =
  let separator = address.rfind(':')
  if separator <= 0:
    raise newException(ValueError, "invalid TCP address: " & address)
  var port: int
  if parseInt(address, port, separator + 1) <= 0:
    raise newException(ValueError, "invalid TCP port: " & address)
  (address[0..<separator], Port(port))

proc recvCborRpcFrame*(socket: Socket, timeout = 2_000): string =
  let header = socket.recv(7, timeout)
  if header.len != 7 or not header.startsWith("\xD8\x18\x5A"):
    raise newException(ValueError, "invalid CBOR-RPC frame header")
  let size =
    (uint32(header[3].uint8) shl 24) or
    (uint32(header[4].uint8) shl 16) or
    (uint32(header[5].uint8) shl 8) or
    uint32(header[6].uint8)
  if size == 0:
    raise newException(ValueError, "empty CBOR-RPC frame")
  socket.recv(int(size), timeout)
