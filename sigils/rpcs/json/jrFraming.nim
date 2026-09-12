## LSP-compatible Content-Length framing for JSON-RPC messages.

import std/[options, strutils, syncio]

export options

const
  DefaultJsonRpcMaxMessageSize* = 1024 * 1024
  JsonRpcFrameReadSize* = 16 * 1024
  JsonRpcMaxHeaderSize = 16 * 1024

type
  JsonRpcFrameError* = object of CatchableError
    ## Invalid, oversized, or truncated JSON-RPC transport framing.

  JsonRpcFrameParser* = object
    ## Incremental parser for LSP ``Content-Length`` JSON-RPC frames.
    buffer: string
    maxMessageSize: int

proc frameJsonRpcMessage*(
    payload: string,
    maxMessageSize = DefaultJsonRpcMaxMessageSize,
): string =
  ## Prefix a JSON-RPC payload with its byte-length Content-Length header.
  if maxMessageSize <= 0:
    raise newException(
      JsonRpcFrameError,
      "JSON-RPC message size limit must be positive",
    )
  if payload.len > maxMessageSize:
    raise newException(
      JsonRpcFrameError,
      "JSON-RPC message exceeds configured size limit",
    )
  result = "Content-Length: " & $payload.len & "\r\n\r\n" & payload

proc initJsonRpcFrameParser*(
    maxMessageSize = DefaultJsonRpcMaxMessageSize,
): JsonRpcFrameParser =
  ## Initialize an incremental LSP JSON-RPC frame parser.
  if maxMessageSize <= 0:
    raise newException(
      JsonRpcFrameError,
      "JSON-RPC message size limit must be positive",
    )
  JsonRpcFrameParser(maxMessageSize: maxMessageSize)

proc add*(parser: var JsonRpcFrameParser, data: sink string) =
  ## Append bytes received from any stream transport.
  if parser.maxMessageSize <= 0:
    raise newException(JsonRpcFrameError, "JSON-RPC frame parser is not initialized")
  parser.buffer.add(data)

proc hasPendingData*(parser: JsonRpcFrameParser): bool =
  ## Return whether an incomplete header or body is buffered.
  parser.buffer.len > 0

proc headerEnd(data: string): tuple[index: int, separatorLen: int] =
  let crlf = data.find("\r\n\r\n")
  if crlf >= 0:
    return (crlf, 4)
  let lf = data.find("\n\n")
  if lf >= 0:
    return (lf, 2)
  (-1, 0)

proc parseContentLength(headers: string): int =
  var found = false
  for line in headers.splitLines():
    if line.len == 0:
      continue
    let separator = line.find(':')
    if separator <= 0:
      raise newException(
        JsonRpcFrameError,
        "JSON-RPC header must contain a name and colon",
      )
    let name = line[0..<separator].strip().toLowerAscii()
    let value =
      if separator + 1 < line.len:
        line[separator + 1 .. ^1].strip()
      else:
        ""
    if name == "content-length":
      if found:
        raise newException(
          JsonRpcFrameError,
          "JSON-RPC frame contains duplicate Content-Length headers",
        )
      if value.len == 0:
        raise newException(
          JsonRpcFrameError,
          "JSON-RPC Content-Length header must not be empty",
        )
      for character in value:
        if character notin {'0' .. '9'}:
          raise newException(
            JsonRpcFrameError,
            "JSON-RPC Content-Length header must be an unsigned integer",
          )
      try:
        result = parseInt(value)
      except ValueError:
        raise newException(
          JsonRpcFrameError,
          "JSON-RPC Content-Length header is out of range",
        )
      found = true

  if not found:
    raise newException(
      JsonRpcFrameError,
      "JSON-RPC frame is missing a Content-Length header",
    )

proc nextFrame*(parser: var JsonRpcFrameParser): Option[string] =
  ## Return the next complete JSON-RPC payload, or none when more bytes are needed.
  if parser.maxMessageSize <= 0:
    raise newException(JsonRpcFrameError, "JSON-RPC frame parser is not initialized")

  let (endIndex, separatorLen) = headerEnd(parser.buffer)
  if endIndex < 0:
    if parser.buffer.len > JsonRpcMaxHeaderSize:
      raise newException(
        JsonRpcFrameError,
        "JSON-RPC frame headers exceed the configured header limit",
      )
    return none(string)
  if endIndex > JsonRpcMaxHeaderSize:
    raise newException(
      JsonRpcFrameError,
      "JSON-RPC frame headers exceed the configured header limit",
    )

  let contentLength = parseContentLength(parser.buffer[0..<endIndex])
  if contentLength > parser.maxMessageSize:
    raise newException(
      JsonRpcFrameError,
      "JSON-RPC message exceeds configured size limit",
    )

  let bodyStart = endIndex + separatorLen
  let frameEnd = bodyStart + contentLength
  if parser.buffer.len < frameEnd:
    return none(string)

  result = some(parser.buffer[bodyStart..<frameEnd])
  if frameEnd == parser.buffer.len:
    parser.buffer.setLen(0)
  else:
    parser.buffer = parser.buffer[frameEnd .. ^1]

proc readJsonRpcMessage*(
    input: File,
    parser: var JsonRpcFrameParser,
): Option[string] =
  ## Read one complete Content-Length message, blocking until it is available.
  if input.isNil:
    raise newException(ValueError, "JSON-RPC input file must not be nil")

  while true:
    let frame = parser.nextFrame()
    if frame.isSome():
      return frame

    try:
      # ``readBuffer`` is implemented with ``fread`` and can wait for its
      # entire requested buffer on a pipe. ``readChar`` waits for one byte,
      # while stdio still buffers the underlying stream efficiently.
      parser.buffer.add(input.readChar())
    except EOFError:
      if parser.hasPendingData():
        raise newException(
          JsonRpcFrameError,
          "unexpected end of input in JSON-RPC frame",
        )
      return none(string)

proc writeJsonRpcMessage*(
    output: File,
    payload: string,
    maxMessageSize = DefaultJsonRpcMaxMessageSize,
) =
  ## Write one Content-Length message and flush it to the output stream.
  if output.isNil:
    raise newException(ValueError, "JSON-RPC output file must not be nil")
  let frame = frameJsonRpcMessage(payload, maxMessageSize)
  output.write(frame)
  output.flushFile()
