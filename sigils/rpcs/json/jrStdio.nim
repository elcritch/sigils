## LSP-compatible JSON-RPC over stdin and stdout.

import std/[syncio]

import ../../[agents, core]
import jrAgents
import jrFraming

export jrAgents, jrFraming

const JsonRpcStdioConnectionId* = JsonRpcDefaultConnectionId

type
  JsonRpcStdioIo* = ref object of JsonRpcIoAgent
    ## Synchronous Content-Length transport for one stdin/stdout connection.
    input: File
    output: File
    parser: JsonRpcFrameParser
    maxMessageSize: int
    running: bool

method startIo*(self: JsonRpcStdioIo) {.gcsafe.} =
  if self.running:
    return
  self.running = true
  emit self.jsonRpcStarted("stdio")

method stopIo*(self: JsonRpcStdioIo) {.gcsafe.} =
  if not self.running:
    return
  self.running = false
  emit self.jsonRpcStopped()

method queueResponse*(
    self: JsonRpcStdioIo,
    response: sink JsonRpcResponse,
) {.gcsafe.} =
  ## Write one response or outbound request/notification to stdout.
  if not self.running:
    return
  self.output.writeJsonRpcMessage(response.data, self.maxMessageSize)

proc pollJsonRpcStdio*(self: JsonRpcStdioIo): bool =
  ## Read and dispatch one complete stdin message.
  ##
  ## This proc blocks until a complete frame arrives or stdin reaches EOF. It
  ## is intended for a local application loop, where the connected dispatcher
  ## runs on the same Sigils scheduler.
  if self.isNil or not self.running:
    return false
  try:
    let frame = self.input.readJsonRpcMessage(self.parser)
    if frame.isNone():
      self.stopIo()
      return false
    emit self.jsonRpcRequestReceived(JsonRpcRequest(
      connectionId: JsonRpcStdioConnectionId,
      data: frame.get(),
    ))
    true
  except CatchableError:
    self.stopIo()
    raise

proc runJsonRpcStdio*(self: JsonRpcStdioIo) =
  ## Run a blocking stdin/stdout loop until EOF or ``stopIo`` is called.
  if self.isNil:
    raise newException(ValueError, "JSON-RPC stdio I/O must not be nil")
  self.startIo()
  while self.running:
    if not self.pollJsonRpcStdio():
      break

proc newJsonRpcStdioIo*(
    input: File = stdin,
    output: File = stdout,
    maxMessageSize = DefaultJsonRpcMaxMessageSize,
): JsonRpcStdioIo =
  ## Create an LSP-style stdin/stdout transport.
  if input.isNil:
    raise newException(ValueError, "JSON-RPC input file must not be nil")
  if output.isNil:
    raise newException(ValueError, "JSON-RPC output file must not be nil")
  if maxMessageSize <= 0:
    raise newException(ValueError, "JSON-RPC message size limit must be positive")
  JsonRpcStdioIo(
    input: input,
    output: output,
    parser: initJsonRpcFrameParser(maxMessageSize),
    maxMessageSize: maxMessageSize,
  )
