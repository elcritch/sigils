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

proc deliverSubscription*(
    sub: Subscription, req: sink SigilRequest, consumes = false
): SigilResponse =
  var ownedReq = ensureMove(req)
  if consumes:
    ownedReq.params.markConsumedDelivery()
  if not sub.endpoint.isNil:
    if not sub.endpoint.isAlive:
      return
    if not sub.endpoint[].dispatchSubscription.isNil:
      when not sigilsSlotEnvDisabled:
        return sub.endpoint[].dispatchSubscription(
          sub.endpoint, ensureMove(ownedReq), sub.packedSlot, sub.envSlot, sub.env
        )
      else:
        return sub.endpoint[].dispatchSubscription(
          sub.endpoint, ensureMove(ownedReq), sub.packedSlot, nil, nil
        )
    if not sub.endpoint[].dispatch.isNil:
      return sub.endpoint[].dispatch(sub.endpoint, ensureMove(ownedReq),
          sub.packedSlot)
  when sigilsSlotEnvDisabled:
    result = sub.tgt[].callMethod(ensureMove(ownedReq), sub.packedSlot)
  else:
    result = sub.tgt[].callMethod(ensureMove(ownedReq), sub)

template callSlotsImpl(
    obj: Agent, req: SigilRequest, subsIter: untyped,
        consumeLast: static bool = true
) =
  template callSubscription(sub: Subscription, isLast: bool) =
    {.cast(gcsafe).}:
      var subReq =
        if isLast and consumeLast:
          move(req)
        else:
          req.clone(sub.cloneMode)
      let res = deliverSubscription(sub, ensureMove(subReq), consumeLast and isLast)
      checkSlotResponse(res)

  var
    pendingSubscription: Subscription
    hasPendingSubscription = false
  for subscription in subsIter:
    # Snapshot the lookahead before the pending slot can mutate the source sequence.
    let nextSubscription = subscription
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
      if not sub.directSlot.isNil and not sub.endpoint.hasDispatcher():
        if sub.endpoint.isNil or sub.endpoint.isAlive:
          if isLast or sub.directSlotClone.isNil:
            sub.directSlot(sub.tgt[], addr args)
          else:
            sub.directSlotClone(sub.tgt[], addr args, sub.cloneMode)
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
        let res = deliverSubscription(sub, ensureMove(req), isLast)
        checkSlotResponse(res)

  var
    pendingSubscription: Subscription
    hasPendingSubscription = false
  for subscription in subsIter:
    # Snapshot the lookahead before the pending slot can mutate the source sequence.
    let nextSubscription = subscription
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

method callSlotsCopy*(obj: Agent, req: SigilRequest) {.base, gcsafe.} =
  ## Dispatch a reusable packed request without consuming its payload.
  let procName = req.procName
  var ownedReq = req
  callSlotsImpl(obj, ownedReq, obj.getSubscriptions(procName), false)

method callSlotsCopy*(obj: AgentActor, req: SigilRequest) {.gcsafe.} =
  obj.ensureActorReady()
  let procName = req.procName
  var subs: seq[Subscription]
  withLock obj.lock:
    for sub in obj.getSubscriptions(procName):
      subs.add(sub)
  var ownedReq = req
  callSlotsImpl(Agent(obj), ownedReq, subs.items, false)

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
    # A sole local slot needs no lookahead snapshot. Borrow its entry only until
    # the call: a slot may disconnect itself or destroy the receiver, so nothing
    # in this entry may be read after invoking it. Actors and proxy dispatch keep
    # the owning snapshots used by the general delivery path.
    if obj.subcriptions.len == 1:
      let entry {.cursor.} = obj.subcriptions[0]
      if entry.signal == procName or entry.signal == AnySigilName:
        let sub {.cursor.} = entry.subscription
        if not sub.directSlot.isNil and not sub.endpoint.hasDispatcher():
          if sub.endpoint.isNil or sub.endpoint.isAlive:
            {.cast(gcsafe).}:
              sub.directSlot(sub.tgt[], addr args)
          return
    callSlotsLocalImpl(obj, procName, origin, args, obj.getSubscriptions(procName))

proc emit*(call: (Agent | WeakRef[Agent], SigilRequest)) =
  var (obj, req) = call
  when obj is WeakRef[Agent]:
    obj[].callSlotsCopy(req)
  else:
    obj.callSlotsCopy(req)

proc emit*[T: Agent, A](call: sink SigilLocalCall[T, A]) =
  var localCall = ensureMove(call)
  localCall.source.callSlotsLocal(localCall.procName, localCall.origin,
      localCall.args)

proc emit*[T: Agent, A](call: sink SigilLocalCall[WeakRef[T], A]) =
  var localCall = ensureMove(call)
  localCall.source[].callSlotsLocal(
    localCall.procName, localCall.origin, localCall.args
  )
