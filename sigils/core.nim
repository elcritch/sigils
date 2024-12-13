import signals
import slots
import threads

export signals, slots, threads

when not defined(gcArc) and not defined(gcOrc) and not defined(nimdoc):
  {.error: "Sigils requires --gc:arc or --gc:orc".}

method callMethod*(
    req: AgentRequest, slot: AgentProc, ctx: RpcContext, # clientId: ClientId,
): AgentResponse {.gcsafe, effectsOf: slot, base.} =
  ## Route's an rpc request. 

  if slot.isNil:
    let msg = req.procName & " is not a registered RPC method."
    let err = AgentError(code: METHOD_NOT_FOUND, msg: msg)
    result = wrapResponseError(req.origin, err)
  else:
    slot(ctx, req.params)
    let res = rpcPack(true)

    result = AgentResponse(kind: Response, id: req.origin, result: res)

proc callSlots*(obj: Agent | WeakRef[Agent], req: AgentRequest) {.gcsafe.} =
  {.cast(gcsafe).}:
    let listeners = obj.toRef().getAgentListeners(req.procName)

    # echo "call slots:req: ", req.repr
    # echo "call slots:all: ", req.procName, " ", obj.agentId, " :: ", obj.listeners

    for (tgt, slot) in listeners.items():
      # echo ""
      # echo "call listener:tgt: ", tgt, " ", req.procName
      # echo "call listener:slot: ", repr slot
      let tgtRef = tgt.toRef()

      var res: AgentResponse

      if tgtRef of AgentProxyShared:
        # echo "threaded Agent!"
        let proxy = AgentProxyShared(tgtRef)
        let sig = ThreadSignal(slot: slot, req: req, tgt: proxy.remote)
        # echo "callMethod:agentProxy: ", "chan: ", $proxy.chan
        let res = proxy.chan.trySend(unsafeIsolate sig)
        if not res:
          raise newException(AgentSlotError, "error sending signal to thread")
      else:
        # echo "regular Thread!"
        res = req.callMethod(slot, tgtRef)

      when defined(nimscript) or defined(useJsonSerde):
        discard
      else:
        discard
        variantMatch case res.result.buf as u
        of AgentError:
          raise newException(AgentSlotError, $u.code & " msg: " & u.msg)
        else:
          discard

proc emit*(call: (Agent | WeakRef[Agent], AgentRequest)) =
  let (obj, req) = call
  callSlots(obj, req)

proc poll*(inputs: Chan[ThreadSignal]) =
  let sig = inputs.recv()
  # echo "thread got request: ", sig, " (", getThreadId(), ")"
  discard sig.req.callMethod(sig.slot, sig.tgt[])

proc poll*(thread: SigilsThread) =
  thread.inputs.poll()

proc execute*(inputs: Chan[ThreadSignal]) =
  while true:
    poll(inputs)

proc execute*(thread: SigilsThread) =
  thread.inputs.execute()

proc runThread*(inputs: Chan[ThreadSignal]) {.thread.} =
  {.cast(gcsafe).}:
    var inputs = inputs
    # echo "sigil thread waiting!", " (", getThreadId(), ")"
    inputs.execute()

proc start*(thread: SigilsThread) =
  createThread(thread.thread, runThread, thread.inputs)

var sigilThread {.threadVar.}: SigilsThread

proc startLocalThread*() =
  if sigilThread.isNil:
    sigilThread = newSigilsThread()

proc getCurrentSigilThread*(): SigilsThread =
  startLocalThread()
  return sigilThread