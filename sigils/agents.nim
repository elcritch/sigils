import std/[options, tables, sets, macros, hashes]
import std/times
import std/isolation
import std/[locks, options]
import stack_strings

import protocol
import weakrefs

export IndexableChars
export weakrefs

when defined(nimscript):
  import std/json
  import ../runtime/jsonutils_lite
  export json
elif defined(useJsonSerde):
  import std/json
  import std/jsonutils
  export json
else:
  import pkg/variant

export protocol
export sets
export options
export variant

type
  AgentObj = object of RootObj
    subscribers*: Table[SigilName, OrderedSet[Subscription]] ## agents listening to me
    subscribedTo*: HashSet[WeakRef[Agent]] ## agents I'm listening to
    when defined(debug):
      freed*: bool
      moved*: bool

  Agent* = ref object of AgentObj

  Subscription* = object
    tgt*: WeakRef[Agent]
    slot*: AgentProc

  # Procedure signature accepted as an RPC call by server
  AgentProc* = proc(context: Agent, params: SigilParams) {.nimcall.}

  AgentProcTy*[S] = AgentProc

  Signal*[S] = AgentProcTy[S]
  SignalTypes* = distinct object

when defined(nimscript):
  proc getId*(a: Agent): SigilId =
    a.debugId

  var lastUId {.compileTime.}: int = 1
else:
  proc getId*[T: Agent](a: WeakRef[T]): SigilId =
    cast[SigilId](a.toPtr())

  proc getId*(a: Agent): SigilId =
    cast[SigilId](cast[pointer](a))

method removeSubscriptionsFor*(
    self: Agent, subscriber: WeakRef[Agent]
) {.base, gcsafe, raises: [].} =
  ## Route's an rpc request. 
  echo "removeSubscriptionsFor ", " self:id: ", $self.getId()
  var delSigs: seq[SigilName]
  var toDel: seq[Subscription]
  for signal, subscriptions in self.subscribers.mpairs():
    echo "removeSubscriptionsFor subs ", signal
    toDel.setLen(0)
    for subscription in subscriptions:
      if subscription.tgt == subscriber:
        toDel.add(subscription)
        # echo "agentRemoved: ", "tgt: ", xid.toPtr.repr, " id: ", agent.debugId, " obj: ", obj[].debugId, " name: ", signal
    for subscription in toDel:
      subscriptions.excl(subscription)
    if subscriptions.len() == 0:
      delSigs.add(signal)
  for sig in delSigs:
    self.subscribers.del(sig)

method unregisterSubscriber*(
    self: Agent, listener: WeakRef[Agent]
) {.base, gcsafe, raises: [].} =
  # echo "\tlisterners: ", subscriber.tgt
  # echo "\tlisterners:subscribed ", subscriber.tgt[].subscribed
  assert listener in self.subscribedTo
  self.subscribedTo.excl(listener)
  # echo "\tlisterners:subscribed ", subscriber.tgt[].subscribed

proc unsubscribe*(subscribedTo: HashSet[WeakRef[Agent]], xid: WeakRef[Agent]) =
  ## unsubscribe myself from agents I'm subscribed (listening) to
  echo "unsubscribe: ", subscribedTo.len
  for obj in subscribedTo.items():
    echo "unsubscribe:obj: ", $obj
  for obj in subscribedTo:
    obj[].removeSubscriptionsFor(xid)

template removeSubscription*(
    subscribers: var Table[SigilName, OrderedSet[Subscription]], xid: WeakRef[Agent]
) =
  ## remove myself from agents listening to me
  for signal, subscriptions in subscribers.mpairs():
    # echo "freeing signal: ", signal, " subscribers: ", subscriberPairs
    for subscription in subscriptions:
      subscription.tgt[].unregisterSubscriber(xid)

proc `=wasMoved`(agent: var AgentObj) =
  let xid: WeakRef[Agent] = WeakRef[Agent](pt: cast[pointer](addr agent))
  echo "agent was moved", " pt: ", xid.toPtr.repr
  agent.moved = true

proc `=destroy`*(agent: AgentObj) =
  let xid: WeakRef[Agent] = WeakRef[Agent](pt: cast[pointer](addr agent))

  echo "\ndestroy: agent: ",
          " pt: ", xid.toPtr.repr,
          " freed: ", agent.freed,
          " moved: ", agent.moved,
          " lstCnt: ", xid[].subscribers.len(),
          " subscribedTo: ", xid[].subscribedTo.len(),
          " (th: ", getThreadId(), ")"
  echo "destroy: agent:st: ", getStackTrace()
  when defined(debug):
    # echo "destroy: agent: ", agent.moved, " freed: ", agent.freed
    if agent.moved:
      raise newException(Defect, "moved!")
    echo "destroy: agent: ", agent.moved, " freed: ", agent.freed
    if agent.freed:
      raise newException(Defect, "already freed!")

  xid[].freed = true
  if xid.toRef().subscribedTo.len() > 0:
    xid.toRef().subscribedTo.unsubscribe(xid)
  if xid.toRef().subscribers.len() > 0:
    xid.toRef().subscribers.removeSubscription(xid)

  # xid[].subscribers[].clear()
  # xid[].subscribedTo[].clear()

  `=destroy`(xid[].subscribers)
  `=destroy`(xid[].subscribedTo)
  echo "finished destroy: agent: ", " pt: ", xid.toPtr.repr

proc `$`*[T: Agent](obj: WeakRef[T]): string =
  result = $(T)
  result &= "{id: "
  result &= obj.getId().pointer
  result &= "}"

proc hash*(a: Agent): Hash =
  hash(a.getId())

proc getSubscriptions*(
    obj: Agent, sig: SigilName
): OrderedSet[Subscription] =
  # echo "FIND:subscribers: ", obj.subscribers
  if obj.subscribers.hasKey(sig):
    result = obj.subscribers[sig]
  elif obj.subscribers.hasKey(AnySigilName):
    result = obj.subscribers[AnySigilName]

template getSubscriptions*(
    obj: Agent, sig: string
): OrderedSet[(WeakRef[Agent], AgentProc)] =
  obj.getSubscriptions(sig)

proc unsafeWeakRef*[T: Agent](obj: T): WeakRef[T] =
  result = WeakRef[T](pt: cast[pointer](obj))

proc asAgent*[T: Agent](obj: WeakRef[T]): WeakRef[Agent] =
  result = WeakRef[Agent](pt: obj.pt)

proc asAgent*[T: Agent](obj: T): Agent =
  result = obj

proc addSubscription*(obj: Agent, sig: SigilName, tgt: Agent, slot: AgentProc): void =
  # echo "add agent listener: ", sig, " obj: ", obj.debugId, " tgt: ", tgt.debugId
  # if obj.subscribers.hasKey(sig):
  #   echo "listener:count: ", obj.subscribers[sig].len()
  assert slot != nil

  obj.subscribers.withValue(sig, agents):
    # if (tgt.unsafeWeakRef(), slot,) notin agents[]:
    #   echo "addAgentsubscribers: ", "tgt: ", tgt.unsafeWeakRef().toPtr().pointer.repr, " id: ", tgt.debugId, " obj: ", obj.debugId, " name: ", sig
    agents[].incl(Subscription(tgt: tgt.unsafeWeakRef(), slot: slot))
  do:
    # echo "addAgentsubscribers: ", "tgt: ", tgt.unsafeWeakRef().toPtr().pointer.repr, " id: ", tgt.debugId, " obj: ", obj.debugId, " name: ", sig
    var agents = initOrderedSet[Subscription]()
    agents.incl(Subscription(tgt: tgt.unsafeWeakRef(), slot: slot))
    obj.subscribers[sig] = ensureMove agents

  tgt.subscribedTo.incl(obj.unsafeWeakRef())
  # echo "subscribers: ", obj.subscribers.len, " SUBSC: ", tgt.subscribed.len

template addSubscription*(
    obj: Agent, sig: IndexableChars, tgt: Agent, slot: AgentProc
): void =
  addSubscription(obj, sig.toSigilName(), tgt, slot)

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
