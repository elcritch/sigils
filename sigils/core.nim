import signals
import slots

export signals, slots

type AgentSlotError* = object of CatchableError

proc callSlots*(obj: Agent | WeakRef[Agent], req: SigilRequest) {.gcsafe.} =
  {.cast(gcsafe).}:
    withRef obj, agent:
      let subscriptions =
          agent.getSubscriptions(req.procName)
        # when typeof(obj) is Agent:
        #   obj.getSubscriptions(req.procName)
        # elif typeof(obj) is WeakRef[Agent]:
        #   obj[].getSubscriptions(req.procName)
        # else:
        #   {.error: "bad type".}
      # echo "call slots:req: ", req.repr
      # echo "call slots:all: ", req.procName, " ", " subscriptions: ", subscriptions
      for sub in subscriptions.items():
        # echo ""
        # echo "call listener:tgt: ", sub.tgt, " ", req.procName
        # echo "call listener:slot: ", repr sub.slot
        withRef sub.tgt, tgtRef:
          # let tgtRef = sub.tgt.toRef()
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
