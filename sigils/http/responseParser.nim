## Incremental HTTP/1.1 response parser for streamed downloads.

import std/[strutils, tables]
import httputils

type
  HttpResponseError* = object of CatchableError
  HttpBodyMode = enum bmHeaders, bmFixed, bmChunkSize, bmChunkData,
    bmChunkEnd, bmTrailers, bmUntilClose, bmDone
  HttpResponseParser* = object
    buffer: string
    mode: HttpBodyMode
    remaining: int64
    total: int64
    maxBody: int64
    maxHeader: int
    status*: int
    headers*: Table[string, string]

proc initHttpResponseParser*(maxBody: Positive = 64 * 1024 * 1024,
    maxHeader: Positive = 32 * 1024): HttpResponseParser =
  result.maxBody = maxBody
  result.maxHeader = maxHeader
  result.headers = initTable[string, string]()

proc isDone*(parser: HttpResponseParser): bool = parser.mode == bmDone

proc invalid(message: string) {.noreturn.} =
  raise newException(HttpResponseError, message)

proc parseLength(s: string, radix: int): int64 =
  if s.len == 0: invalid("empty length")
  for c in s:
    let n = if c in {'0'..'9'}: ord(c) - ord('0')
      elif c in {'a'..'f'}: ord(c) - ord('a') + 10
      elif c in {'A'..'F'}: ord(c) - ord('A') + 10
      else: -1
    if n < 0 or n >= radix or result > (high(int64) - n) div radix:
      invalid("invalid or overflowing length")
    result = result * radix + n

proc consume(parser: var HttpResponseParser, count: int) =
  if count == parser.buffer.len: parser.buffer.setLen(0)
  else: parser.buffer = parser.buffer[count..^1]

proc add*(parser: var HttpResponseParser, data: string): seq[string] =
  ## Feed bytes and return body chunks. Headers are available once status is set.
  if parser.mode == bmDone and data.len > 0: invalid("bytes after response")
  parser.buffer.add(data)
  while true:
    case parser.mode
    of bmHeaders:
      let at = parser.buffer.find("\r\n\r\n")
      if at < 0:
        if parser.buffer.len > parser.maxHeader: invalid("headers too large")
        break
      if at + 4 > parser.maxHeader: invalid("headers too large")
      template headerBytes: untyped = parser.buffer.toOpenArrayByte(0, at + 3)
      let parsed = httputils.parseResponse(headerBytes, false)
      if parsed.failed() or parsed.length != at + 4 or
          parsed.version notin [HttpVersion10, HttpVersion11] or
          parsed.code < 100 or parsed.code > 599:
        invalid("invalid HTTP response headers")
      parser.status = parsed.code
      for key, value in parsed.headers(headerBytes):
        let name = key.toLowerAscii()
        if name in parser.headers:
          if name == "content-length" or name == "transfer-encoding":
            invalid("duplicate framing header")
          parser.headers[name].add(", " & value)
        else:
          parser.headers[name] = value
      parser.consume(at + 4)
      if parser.status < 200: invalid("informational responses are unsupported")
      if parser.status in [204, 304]:
        parser.mode = bmDone
      elif "transfer-encoding" in parser.headers:
        if "content-length" in parser.headers or
            parser.headers["transfer-encoding"].toLowerAscii() != "chunked":
          invalid("unsupported or ambiguous transfer encoding")
        parser.mode = bmChunkSize
      elif "content-length" in parser.headers:
        parser.remaining = parseLength(parser.headers["content-length"], 10)
        if parser.remaining > parser.maxBody: invalid("body too large")
        parser.mode = if parser.remaining == 0: bmDone else: bmFixed
      else: parser.mode = bmUntilClose
    of bmFixed, bmChunkData:
      if parser.buffer.len == 0: break
      let count = min(parser.remaining, int64(parser.buffer.len)).int
      parser.total += count
      if parser.total > parser.maxBody: invalid("body too large")
      result.add(parser.buffer[0..<count])
      parser.consume(count)
      parser.remaining -= count
      if parser.remaining == 0:
        parser.mode = if parser.mode == bmFixed: bmDone else: bmChunkEnd
    of bmChunkSize:
      let at = parser.buffer.find("\r\n")
      if at < 0:
        if parser.buffer.len > parser.maxHeader: invalid("chunk header too large")
        break
      if at > parser.maxHeader: invalid("chunk header too large")
      let line = parser.buffer[0..<at]
      let semicolon = line.find(';')
      let size = if semicolon < 0: line else: line[0..<semicolon]
      parser.remaining = parseLength(size, 16)
      if parser.remaining > parser.maxBody - parser.total: invalid("body too large")
      parser.consume(at + 2)
      parser.mode = if parser.remaining == 0: bmTrailers else: bmChunkData
    of bmChunkEnd:
      if parser.buffer.len < 2: break
      if parser.buffer[0..1] != "\r\n": invalid("invalid chunk ending")
      parser.consume(2)
      parser.mode = bmChunkSize
    of bmTrailers:
      if parser.buffer.len < 2: break
      if parser.buffer[0..1] == "\r\n":
        parser.consume(2)
        parser.mode = bmDone
      else:
        let at = parser.buffer.find("\r\n\r\n")
        if at < 0:
          if parser.buffer.len > parser.maxHeader: invalid("trailers too large")
          break
        if at + 4 > parser.maxHeader: invalid("trailers too large")
        parser.consume(at + 4)
        parser.mode = bmDone
    of bmUntilClose:
      if parser.buffer.len == 0: break
      parser.total += parser.buffer.len
      if parser.total > parser.maxBody: invalid("body too large")
      result.add(move parser.buffer)
      parser.buffer = ""
      break
    of bmDone:
      if parser.buffer.len > 0: invalid("bytes after response")
      break

proc finish*(parser: var HttpResponseParser) =
  ## Report end of stream, rejecting truncated responses.
  if parser.mode == bmUntilClose: parser.mode = bmDone
  if parser.mode != bmDone: invalid("truncated HTTP response")
