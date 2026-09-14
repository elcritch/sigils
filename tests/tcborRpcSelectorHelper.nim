when defined(features.sigils.cbor) or defined(features.sigils.ipc):
  import std/[net, unittest]

  import sigils
  import sigils/threadSelectors
  import sigils/rpcs/cborRpc
  import sigils/rpcs/cbor/[crAgents, crFraming, crSelector]

  import cborRpcTestUtils

  type AddArgs = tuple[left: int, right: int]

  let addNumbers = selector[AddArgs, int]("addNumbers")

  proc addImpl(self: DynamicAgent, args: AddArgs): int =
    args.left + args.right

  suite "CBOR-RPC selector helper thread":
    test "returns protocol dispatch to the application thread":
      startLocalThreadDefault()
      let
        home = getCurrentSigilThread()
        helper = newSigilSelectorThread()
        calculator = DynamicAgent()
        router = newCborRpcRouter()
        dispatcher = newCborRpcDispatcher(router)

      discard calculator.addMethod(addNumbers, toDynamicMethod(addImpl))
      router.registerSelector("calculator", calculator, addNumbers)

      block ioLifetime:
        var io = newCborRpcSelectorIo()
        let proxy = io.moveToThread(helper)
        dispatcher.connectCborRpc(proxy)
        helper.start()
        emit dispatcher.cborRpcStartRequested()
        while not dispatcher.isListening:
          discard home.poll()

        let
          remote = splitTcpAddress(dispatcher.boundAddress)
          socket = newSocket(buffered = false)
          request = encodeCborRpcEnvelope(cborRpcRequestEnvelope(
            5,
            "calculator",
            "addNumbers",
            packCborRpcPayload((left: 5, right: 6)),
          ))
        try:
          socket.connect(remote.host, remote.port)
          socket.send(frameCborRpcPayload(request))
          discard home.poll()
          let response = decodeCborRpcEnvelope(socket.recvCborRpcFrame())
          check unpackCborRpcPayload(response.payload, int) == 11
        finally:
          socket.close()

        emit dispatcher.cborRpcStopRequested()
        while dispatcher.isListening:
          discard home.poll()

      helper.stop()
      helper.join()
      helper.closeSelectorThread()
