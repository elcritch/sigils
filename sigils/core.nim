import signals
import slots

export signals, slots

type AgentSlotError* = object of CatchableError

proc callSlots*(obj: Agent | WeakRef[Agent], req: SigilRequest) {.gcsafe.} =
  {.cast(gcsafe).}:
    let subscriptions = obj.toRef().getSubscriptions(req.procName)
    # echo "call slots:req: ", req.repr
    # echo "call slots:all: ", req.procName, " ", obj.agentId, " :: ", obj.listeners
    for sub in subscriptions.items():
      # echo ""
      # echo "call listener:tgt: ", tgt, " ", req.procName
      # echo "call listener:slot: ", repr slot
      let tgtRef = sub.tgt.toRef()
      var res: SigilResponse = tgtRef.callMethod(req, sub.slot)

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
