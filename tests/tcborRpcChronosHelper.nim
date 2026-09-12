when (defined(features.sigils.cbor) or defined(features.sigils.ipc)) and
    defined(features.sigils.chronos):
  import std/[net, unittest]

  import sigils
  import sigils/threadChronos
  import sigils/rpcs/cborRpc
  import sigils/rpcs/cbor/[crAgents, crChronos, crFraming]

  import cborRpcTestUtils

  type AddArgs = tuple[left: int, right: int]

  let addNumbers = selector[AddArgs, int]("addNumbers")

  proc addImpl(self: DynamicAgent, args: AddArgs): int =
    args.left + args.right

  suite "CBOR-RPC Chronos helper thread":
    test "returns protocol dispatch to the application thread":
      startLocalThreadDefault()
      let
        home = getCurrentSigilThread()
        helper = newSigilChronosThread()
        calculator = DynamicAgent()
        router = newCborRpcRouter()
        dispatcher = newCborRpcDispatcher(router)

      discard calculator.addMethod(addNumbers, toDynamicMethod(addImpl))
      router.registerSelector("calculator", calculator, addNumbers)

      block ioLifetime:
        var io = newCborRpcChronosIo()
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
            6,
            "calculator",
            "addNumbers",
            packCborRpcPayload((left: 9, right: 8)),
          ))
        try:
          socket.connect(remote.host, remote.port)
          socket.send(frameCborRpcPayload(request))
          discard home.poll()
          let response = decodeCborRpcEnvelope(socket.recvCborRpcFrame())
          check unpackCborRpcPayload(response.payload, int) == 17
        finally:
          socket.close()

        emit dispatcher.cborRpcStopRequested()
        while dispatcher.isListening:
          discard home.poll()

      helper.stop()
      helper.join()
