import signals
import slots
import threads

export signals, slots, threads

proc callSlots*(obj: Agent | WeakRef[Agent], req: SigilRequest) {.gcsafe.} =
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

proc emit*(call: (Agent | WeakRef[Agent], SigilRequest)) =
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
