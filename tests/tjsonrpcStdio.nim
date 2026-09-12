import std/[json, options, os, syncio, unittest]

import sigils/rpcs/json/[jrFraming, jrStdio]

include jsonrpcCases

proc writeFileBytes(path, data: string) =
  var file: File
  check open(file, path, fmWrite)
  file.write(data)
  file.close()

suite "JSON-RPC Content-Length framing":
  test "parses fragmented UTF-8 LSP frames and coalesced messages":
    let
      first = "{\"jsonrpc\":\"2.0\",\"method\":\"initialize\",\"id\":1,\"title\":\"λ\"}"
      second = "{\"jsonrpc\":\"2.0\",\"method\":\"initialized\"}"
      wire = frameJsonRpcMessage(first) & frameJsonRpcMessage(second)
    var parser = initJsonRpcFrameParser()
    var frames: seq[string]

    for index in 0 ..< wire.len:
      parser.add(wire[index .. index])
      var frame = parser.nextFrame()
      while frame.isSome():
        frames.add(frame.get())
        frame = parser.nextFrame()

    check frames == @[first, second]
    check not parser.hasPendingData()

  test "uses byte length for non-ASCII payloads":
    let payload = "{\"message\":\"λ\"}"
    let wire = frameJsonRpcMessage(payload)
    check wire.startsWith("Content-Length: " & $payload.len & "\r\n\r\n")

  test "recognizes peer responses without generating another response":
    let adapter = newJsonRpcAdapter()
    check isJsonRpcResponse(
      "{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"ok\":true}}"
    )
    check isJsonRpcResponse(
      "[{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":null}]"
    )
    check not isJsonRpcResponse(
      "{\"jsonrpc\":\"2.0\",\"method\":\"initialized\"}"
    )
    let handled = adapter.handleJsonRpc(
      "{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":null}"
    )
    check handled.isNone()

  test "builds outbound LSP requests and notifications":
    let
      request = newJsonRpcRequest(
        %7,
        "workspace/configuration",
        %*{"items": []},
      )
      notification = newJsonRpcNotification(
        "window/logMessage",
        %*{"type": 3, "message": "ready"},
      )
    check request["jsonrpc"].getStr() == "2.0"
    check request["method"].getStr() == "workspace/configuration"
    check request["id"].getInt() == 7
    check request["params"]["items"].kind == JArray
    check notification["method"].getStr() == "window/logMessage"
    check notification["params"]["type"].getInt() == 3

  test "rejects missing, duplicate, and oversized headers":
    var parser = initJsonRpcFrameParser(8)
    parser.add("Content-Type: application/vscode-jsonrpc\r\n\r\n{}")
    expect JsonRpcFrameError:
      discard parser.nextFrame()

    parser = initJsonRpcFrameParser()
    parser.add("Content-Length: 1\r\nContent-Length: 1\r\n\r\nx")
    expect JsonRpcFrameError:
      discard parser.nextFrame()

    parser = initJsonRpcFrameParser(1)
    parser.add("Content-Length: 2\r\n\r\n{}")
    expect JsonRpcFrameError:
      discard parser.nextFrame()

  test "keeps exact method names for LSP-style registration":
    startLocalThreadDefault()
    let
      agent = DynamicAgent()
      adapter = newJsonRpcAdapter()
      initialize = selector[tuple[], int]("initialize")
      hover = selector[tuple[], int]("hover")

    proc initializeImpl(self: DynamicAgent, args: tuple[]): int =
      1

    proc hoverImpl(self: DynamicAgent, args: tuple[]): int =
      2

    discard agent.addMethod(initialize, toDynamicMethod(initializeImpl))
    discard agent.addMethod(hover, toDynamicMethod(hoverImpl))
    adapter.registerSelectorMethod("initialize", agent, initialize)
    adapter.registerSelectorMethod("textDocument/hover", agent, hover)

    let initializeReply = adapter.handleJsonRpc(
      """{"jsonrpc":"2.0","method":"initialize","id":1}"""
    )
    check initializeReply.isSome()
    check parseJson(initializeReply.get())["result"].getInt() == 1

    let hoverReply = adapter.handleJsonRpc(
      """{"jsonrpc":"2.0","method":"textDocument/hover","id":2}"""
    )
    check hoverReply.isSome()
    check parseJson(hoverReply.get())["result"].getInt() == 2

suite "JSON-RPC stdio transport":
  test "dispatches Content-Length messages and writes framed replies":
    startLocalThreadDefault()
    let
      inputPath = getTempDir() / "sigils-jsonrpc-stdio-input.json"
      outputPath = getTempDir() / "sigils-jsonrpc-stdio-output.json"
      request = "{\"jsonrpc\":\"2.0\",\"method\":\"calculator.addNumbers\",\"params\":[20,22],\"id\":7}"

    writeFileBytes(inputPath, frameJsonRpcMessage(request))
    var input = open(inputPath, fmRead)
    var output = open(outputPath, fmWrite)
    try:
      let
        adapter = newJsonRpcAdapter()
        calculator = DynamicAgent()
        io = newJsonRpcStdioIo(input, output)
        dispatcher = newJsonRpcDispatcher(adapter)
      discard calculator.addMethod(addNumbers, toDynamicMethod(addImpl))
      adapter.registerSelector("calculator", calculator, addNumbers)
      dispatcher.connectJsonRpc(io)
      emit dispatcher.jsonRpcStartRequested()

      check dispatcher.isListening
      check io.pollJsonRpcStdio()
      dispatcher.sendJsonRpcNotification(
        "window/logMessage",
        %*{"type": 3, "message": "ready"},
      )
      check not io.pollJsonRpcStdio()
      output.flushFile()
    finally:
      input.close()
      output.close()

    var outputParser = initJsonRpcFrameParser()
    outputParser.add(readFile(outputPath))
    let encodedReply = outputParser.nextFrame()
    check encodedReply.isSome()
    let reply = parseJson(encodedReply.get())
    check reply["result"].getInt() == 42
    check reply["id"].getInt() == 7
    let notification = outputParser.nextFrame()
    check notification.isSome()
    check parseJson(notification.get())["method"].getStr() == "window/logMessage"
    check not outputParser.hasPendingData()
    removeFile(inputPath)
    removeFile(outputPath)
