import signals
import slots

from system/ansi_c import c_raise

export signals, slots

type AgentSlotError* = object of CatchableError

proc callSlots*(obj: Agent | WeakRef[Agent], req: SigilRequest) {.gcsafe.} =
  {.cast(gcsafe).}:
    let subscriptions =
      when typeof(obj) is Agent:
        obj.getSubscriptions(req.procName)
      elif typeof(obj) is WeakRef[Agent]:
        obj[].getSubscriptions(req.procName)
      else:
        {.error: "bad type".}
    # echo "call slots:req: ", req.repr
    # echo "call slots:all: ", req.procName, " ", " subscriptions: ", subscriptions
    for sub in subscriptions.items():
      # echo ""
      # echo "call listener:tgt: ", sub.tgt, " ", req.procName
      # echo "call listener:slot: ", repr sub.slot
      # let tgtRef = sub.tgt.toRef()
      when defined(sigilDebugFreed):
        if sub.tgt[].freedByThread != 0:
          echo "exec:call:thread: ", $getThreadId()
          echo "exec:call:sub.tgt[].freed:thread: ", $sub.tgt[].freedByThread
          echo "exec:call:sub.tgt[]:id: ", $sub.tgt[].getId()
          echo "exec:call:sub.req: ", req.repr
          echo "exec:call:obj:id: ", $obj.getId()
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
