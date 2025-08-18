import signals
import slots
import agents

when defined(sigilsDebug):
  from system/ansi_c import c_raise

export signals, slots, agents

method callMethod*(
    ctx: Agent, req: SigilRequest, slot: AgentProc
): SigilResponse {.base, gcsafe, effectsOf: slot.} =
  ## Route's an rpc request. 

  if slot.isNil:
    let msg = $req.procName & " is not a registered RPC method."
    let err = SigilError(code: METHOD_NOT_FOUND, msg: msg)
    result = wrapResponseError(req.origin, err)
  else:
    slot(ctx, req.params)
    let res = rpcPack(true)

    result = SigilResponse(kind: Response, id: req.origin.int, result: res)

from system/ansi_c import c_raise

type AgentSlotError* = object of CatchableError

proc callSlots*(obj: Agent | WeakRef[Agent], req: SigilRequest) {.gcsafe.} =
  {.cast(gcsafe).}:
    # echo "call slots:req: ", req.repr
    # echo "call slots:all: ", req.procName, " ", " subscriptions: ", subscriptions
    for sub in obj.getSubscriptions(req.procName):
      # echo ""
      # echo "call listener:tgt: ", sub.tgt, " ", req.procName
      # echo "call listener:slot: ", repr sub.slot
      # let tgtRef = sub.tgt.toRef()
      when defined(sigilsDebug):
        if sub.tgt[].freedByThread != 0:
          echo "exec:call:thread: ", $getThreadId()
          echo "exec:call:sub.tgt[].freed:thread: ", $sub.tgt[].freedByThread
          echo "exec:call:sub.tgt[]:id: ", $sub.tgt[].getSigilId()
          echo "exec:call:sub.req: ", req.repr
          echo "exec:call:obj:id: ", $obj.getSigilId()
          discard c_raise(11.cint)
        assert sub.tgt[].freedByThread == 0
      var res: SigilResponse = sub.tgt[].callMethod(req, sub.slot)

      when defined(nimscript) or defined(useJsonSerde):
        discard
      else:
        discard
        variantMatch case res.result.buf as u
        of SigilError:
          raise newException(AgentSlotError, $u.code & " msg: " & u.msg)
        else:
          discard

proc emit*(call: (Agent | WeakRef[Agent], SigilRequest)) =
  let (obj, req) = call
  callSlots(obj, req)
