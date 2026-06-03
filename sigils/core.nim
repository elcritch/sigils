import std/locks

import signals
import slots
import agents
import actors

when defined(sigilsDebug):
  from system/ansi_c import c_raise

export signals, slots, agents

method callMethod*(
    ctx: Agent, req: SigilRequest, slot: AgentProc
): SigilResponse {.base, gcsafe, effectsOf: slot.} =
  ## Route a sigil request.
  debugPrint "callMethod: normal: ",
    $ctx.unsafeWeakRef().asAgent(),
    " slot: ",
    repr(slot)

  if slot.isNil:
    let msg = $req.procName & " is not a registered sigil method."
    let err = SigilError(code: METHOD_NOT_FOUND, msg: msg)
    result = wrapResponseError(req.origin, err)
  else:
    slot(ctx, req.params)
    let res = rpcPack(true)

    result = SigilResponse(kind: Response, id: req.origin.int, result: res)

when not sigilsSlotEnvDisabled:
  method callMethod*(
      ctx: Agent, req: SigilRequest, subscription: Subscription
  ): SigilResponse {.base, gcsafe.} =
    ## Route a sigil request through a static slot or an env-backed closure slot.
    if subscription.envSlot.isNil:
      {.cast(gcsafe).}:
        result = ctx.callMethod(req, subscription.packedSlot)
    else:
      {.cast(gcsafe).}:
        subscription.envSlot(ctx, req.params, subscription.env)
      let res = rpcPack(true)
      result = SigilResponse(kind: Response, id: req.origin.int, result: res)

from system/ansi_c import c_raise

type AgentSlotError* = object of CatchableError

template checkSlotResponse(res: SigilResponse) =
  when defined(nimscript) or defined(useJsonSerde):
    discard
  elif defined(sigilsCborSerde):
    discard
  else:
    variantMatch case res.result.buf as u
    of SigilError:
      raise newException(AgentSlotError, $u.code & " msg: " & u.msg)
    else:
      discard

template callSlotsImpl(obj: Agent, req: SigilRequest, subsIter: untyped) =
  for sub in subsIter:
    {.cast(gcsafe).}:
      when defined(sigilsDebug):
        if sub.tgt[].freedByThread != 0:
          debugPrint "exec:call:thread: ", $getThreadId()
          debugPrint "exec:call:sub.tgt[].freed:thread: ", $sub.tgt[].freedByThread
          debugPrint "exec:call:sub.tgt[]:id: ", $sub.tgt[].getSigilId()
          debugPrint "exec:call:sub.req: ", req.repr
          debugPrint "exec:call:obj:id: ", $obj.getSigilId()
          discard c_raise(11.cint)
        assert sub.tgt[].freedByThread == 0
      when sigilsSlotEnvDisabled:
        var res: SigilResponse = sub.tgt[].callMethod(req, sub.packedSlot)
      else:
        var res: SigilResponse = sub.tgt[].callMethod(req, sub)

      checkSlotResponse(res)

template callSlotsLocalImpl(
    obj: Agent,
    procName: SigilName,
    origin: SigilId,
    args: untyped,
    subsIter: untyped
) =
  var
    reqReady = false
    req: SigilRequest
  for sub in subsIter:
    {.cast(gcsafe).}:
      if not sub.directSlot.isNil:
        sub.directSlot(sub.tgt[], addr args)
      else:
        if not reqReady:
          req = initSigilRequest[typeof(obj), typeof(args)](
            procName = procName, args = args, origin = origin
          )
          reqReady = true
        when sigilsSlotEnvDisabled:
          var res: SigilResponse = sub.tgt[].callMethod(req, sub.packedSlot)
        else:
          var res: SigilResponse = sub.tgt[].callMethod(req, sub)
        checkSlotResponse(res)

method callSlots*(obj: Agent, req: SigilRequest) {.base, gcsafe.} =
  callSlotsImpl(obj, req, obj.getSubscriptions(req.procName))

method callSlots*(obj: AgentActor, req: SigilRequest) {.gcsafe.} =
  obj.ensureActorReady()
  var subs: seq[Subscription]
  withLock obj.lock:
    for sub in obj.getSubscriptions(req.procName):
      subs.add(sub)
  callSlotsImpl(Agent(obj), req, subs.items)

proc callSlotsLocal*[A](
    obj: Agent, procName: SigilName, origin: SigilId, args: var A
) {.gcsafe.} =
  if obj of AgentActor:
    let actor = AgentActor(obj)
    actor.ensureActorReady()
    var subs: seq[Subscription]
    withLock actor.lock:
      for sub in actor.getSubscriptions(procName):
        subs.add(sub)
    callSlotsLocalImpl(Agent(actor), procName, origin, args, subs.items)
  else:
    callSlotsLocalImpl(obj, procName, origin, args, obj.getSubscriptions(procName))

proc emit*(call: (Agent | WeakRef[Agent], SigilRequest)) =
  let (obj, req) = call
  when obj is WeakRef[Agent]:
    obj[].callSlots(req)
  else:
    obj.callSlots(req)

proc emit*[T: Agent, A](call: sink SigilLocalCall[T, A]) =
  var localCall = call
  localCall.source.callSlotsLocal(
    localCall.procName, localCall.origin, localCall.args
  )

proc emit*[T: Agent, A](call: sink SigilLocalCall[WeakRef[T], A]) =
  var localCall = call
  localCall.source[].callSlotsLocal(
    localCall.procName, localCall.origin, localCall.args
  )
