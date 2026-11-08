when defined(features.sigils.ipc):
  import std/[net, unittest]
  import sigils
  import sigils/threadSelectors
  import sigils/ipc/selectorPeer

  type Observer = ref object of Agent
    server: SelectorIpcPeer
    reply: IpcEnvelope
    received: bool
    failedId: uint64
    failure: string
    router: IpcRouter
    calculator: DynamicAgent

  type AddArgs = tuple[left: int, right: int]
  let addNumbers = selector[AddArgs, int]("addNumbers")

  proc addImpl(self: DynamicAgent, args: AddArgs): int =
    args.left + args.right

  proc onAccept(self: Observer, stream: SelectorStream) {.slot.} =
    self.server = newSelectorIpcPeer(stream, self.router)

  proc onReply(self: Observer, response: IpcEnvelope) {.slot.} =
    self.reply = response
    self.received = true

  proc onFailure(self: Observer, id: uint64, error: string) {.slot.} =
    self.failedId = id
    self.failure = error

  suite "selector IPC peer":
    test "reports a pending call when the peer closes":
      let thread = newSigilSelectorThread()
      setLocalSigilThread(thread)
      let listener = listenTcp(thread)
      let stream = connectTcp(thread, "127.0.0.1", listener.localAddress().port)
      let peer = newSelectorIpcPeer(stream)
      let observer = Observer()
      connect(peer, ipcRequestFailed, observer, onFailure)
      let id = peer.callRaw("target", "method", packIpcPayload(()))
      peer.close()
      check observer.failedId == id
      check observer.failure.len > 0
      listener.close()
      thread.closeSelectorThread()

    test "correlates remote route errors over a selector stream":
      let thread = newSigilSelectorThread()
      setLocalSigilThread(thread)
      let listener = listenTcp(thread)
      let observer = Observer(router: newIpcRouter(), calculator: DynamicAgent())
      discard observer.calculator.addMethod(addNumbers, toDynamicMethod(addImpl))
      observer.router.registerSelector("calculator", observer.calculator, addNumbers)
      connect(listener, streamAccepted, observer, onAccept)
      let stream = connectTcp(thread, "127.0.0.1", listener.localAddress().port)
      let peer = newSelectorIpcPeer(stream)
      connect(peer, ipcResponse, observer, onReply)
      let id = peer.callRaw("missing", "method", packIpcPayload(()))
      for i in 0..<200:
        discard thread.poll()
        if observer.received:
          break
      check observer.received
      check observer.reply.id == id
      check observer.reply.kind == IpcError
      check observer.reply.errorCode == IpcMethodNotFound
      observer.received = false
      let successId = peer.callRaw("calculator", "addNumbers",
        packIpcPayload((left: 19, right: 23)))
      for i in 0..<200:
        discard thread.poll()
        if observer.received:
          break
      check observer.received
      check observer.reply.id == successId
      check observer.reply.kind == IpcResponse
      check unpackIpcPayload(observer.reply.payload, int) == 42
      peer.close()
      if not observer.server.isNil:
        observer.server.close()
      listener.close()
      thread.closeSelectorThread()
