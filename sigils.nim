
import sigils/signals
import sigils/slots
import sigils/threads

export signals, slots, threads

when not defined(gcArc) and not defined(gcOrc) and not defined(nimdoc):
  {.error: "Sigils requires --gc:arc or --gc:orc".}

proc wrapResponse*(id: AgentId, resp: RpcParams, kind = Response): AgentResponse = 
  # echo "WRAP RESP: ", id, " kind: ", kind
  result.kind = kind
  result.id = id
  result.result = resp

proc wrapResponseError*(id: AgentId, err: AgentError): AgentResponse = 
  echo "WRAP ERROR: ", id, " err: ", err.repr
  result.kind = Error
  result.id = id
  result.result = rpcPack(err)

proc callMethod*(
    slot: AgentProc,
    ctx: RpcContext,
    req: AgentRequest,
    # clientId: ClientId,
): AgentResponse {.gcsafe, effectsOf: slot.} =
  ## Route's an rpc request. 

  if slot.isNil:
    let msg = req.procName & " is not a registered RPC method."
    let err = AgentError(code: METHOD_NOT_FOUND, msg: msg)
    result = wrapResponseError(req.origin, err)
  else:
    slot(ctx, req.params)
    let res = rpcPack(true)

    result = AgentResponse(kind: Response, id: req.origin, result: res)

template packResponse*(res: AgentResponse): Variant =
  var so = newVariant()
  so.pack(res)
  so

proc callSlots*(obj: Agent | WeakRef[Agent], req: AgentRequest) {.gcsafe.} =
  {.cast(gcsafe).}:
    let listeners = obj.toRef().getAgentListeners(req.procName)

    # echo "call slots:req: ", req.repr
    # echo "call slots:all: ", req.procName, " ", obj.agentId, " :: ", obj.listeners

    for (tgt, slot) in listeners.items():
      echo ""
      echo "call listener:tgt: ", tgt, " ", req.procName
      # echo "call listener:slot: ", repr slot
      let tgtRef = tgt.toRef()

      var res: AgentResponse

      if tgtRef of AgentRouter:
        echo "threaded Agent!"
        let router = AgentRouter(tgtRef)
        let sig = ThreadSignal(slot: slot, req: req, tgt: router.remote)
        let res = router.chan.trySend(unsafeIsolate sig)
        if not res:
          raise newException(AgentSlotError, "error sending signal to thread")

      else:
        echo "regular Thread!"
        res = slot.callMethod(tgtRef, req)

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

proc runThread*(inputs: Chan[ThreadSignal]) {.thread.} =
  {.cast(gcsafe).}:
    echo "sigil thread waiting!"
    while true:
      let sig = inputs.recv()
      echo "thread got request: ", sig
      discard sig.slot.callMethod(sig.tgt[], sig.req)

proc start*(thread: SigilsThread) =
  createThread(thread.thread, runThread, thread.inputs)
