import std/locks

import signals
import slots
import agents
import actors

when defined(sigilsDebug):
  from system/ansi_c import c_raise

export signals, slots, agents

method callMethod*(
    ctx: Agent, req: sink SigilRequest, slot: AgentProc
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
      ctx: Agent, req: sink SigilRequest, subscription: Subscription
  ): SigilResponse {.base, gcsafe.} =
    ## Route a sigil request through a static slot or an env-backed closure slot.
    if subscription.envSlot.isNil:
      {.cast(gcsafe).}:
        result = ctx.callMethod(ensureMove(req), subscription.packedSlot)
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
  elif sigilsCborSerdeEnabled:
    discard
  else:
    variantMatch case res.result.payload as u
    of SigilError:
      raise newException(AgentSlotError, $u.code & " msg: " & u.msg)
    else:
      discard

template callSlotsImpl(obj: Agent, req: SigilRequest, subsIter: untyped) =
  template callSubscription(sub: Subscription, isLast: bool) =
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
      var subReq =
        if isLast:
          move(req)
        else:
          req.clone(sub.cloneMode)
      when sigilsSlotEnvDisabled:
        var res: SigilResponse = sub.tgt[].callMethod(
          ensureMove(subReq), sub.packedSlot
        )
      else:
        var res: SigilResponse = sub.tgt[].callMethod(ensureMove(subReq), sub)

      checkSlotResponse(res)

  var
    pendingSubscription {.cursor.}: Subscription
    hasPendingSubscription = false
  for subscription in subsIter:
    # Snapshot the lookahead before the pending slot can mutate the source sequence.
    let nextSubscription {.cursor.} = subscription
    if hasPendingSubscription:
      callSubscription(pendingSubscription, false)
    pendingSubscription = nextSubscription
    hasPendingSubscription = true

  if hasPendingSubscription:
    callSubscription(pendingSubscription, true)

template callSlotsLocalImpl(
    obj: Agent,
    procName: SigilName,
    origin: SigilId,
    args: untyped,
    subsIter: untyped
) =
  template callSubscription(sub: Subscription, isLast: bool) =
    {.cast(gcsafe).}:
      if not sub.directSlot.isNil:
        sub.directSlot(sub.tgt[], addr args)
      else:
        var req =
          if isLast:
            initSigilRequest[typeof(obj), typeof(args)](
              procName = procName,
              args = move(args),
              origin = origin,
            )
          else:
            initSigilRequest[typeof(obj), typeof(args)](
              procName = procName,
              args = args.cloneForDelivery(sub.cloneMode),
              origin = origin,
            )
        when sigilsSlotEnvDisabled:
          var res: SigilResponse = sub.tgt[].callMethod(
            ensureMove(req), sub.packedSlot
          )
        else:
          var res: SigilResponse = sub.tgt[].callMethod(ensureMove(req), sub)
        checkSlotResponse(res)

  var
    pendingSubscription {.cursor.}: Subscription
    hasPendingSubscription = false
  for subscription in subsIter:
    # Snapshot the lookahead before the pending slot can mutate the source sequence.
    let nextSubscription {.cursor.} = subscription
    if hasPendingSubscription:
      callSubscription(pendingSubscription, false)
    pendingSubscription = nextSubscription
    hasPendingSubscription = true

  if hasPendingSubscription:
    callSubscription(pendingSubscription, true)

method callSlots*(obj: Agent, req: sink SigilRequest) {.base, gcsafe.} =
  let procName = req.procName
  var ownedReq = ensureMove(req)
  callSlotsImpl(obj, ownedReq, obj.getSubscriptions(procName))

method callSlots*(obj: AgentActor, req: sink SigilRequest) {.gcsafe.} =
  obj.ensureActorReady()
  let procName = req.procName
  var subs: seq[Subscription]
  withLock obj.lock:
    for sub in obj.getSubscriptions(procName):
      subs.add(sub)
  var ownedReq = ensureMove(req)
  callSlotsImpl(Agent(obj), ownedReq, subs.items)

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
  var (obj, req) = call
  when obj is WeakRef[Agent]:
    obj[].callSlots(ensureMove(req))
  else:
    obj.callSlots(ensureMove(req))

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
