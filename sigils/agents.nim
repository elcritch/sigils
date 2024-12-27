import std/[options, tables, sets, macros, hashes]
import std/times
import std/isolation
import std/[locks, options]

import protocol
import stack_strings

export IndexableChars

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

type WeakRef*[T] = object
  pt* {.cursor.}: T
  ## type alias descring a weak ref that *must* be cleaned
  ## up when an object is set to be destroyed

proc `=destroy`*[T](obj: WeakRef[T]) =
  discard

proc `[]`*[T](r: WeakRef[T]): lent T =
  result = r.pt

proc toPtr*[T](obj: WeakRef[T]): pointer =
  result = cast[pointer](obj.pt)

proc hash*[T](obj: WeakRef[T]): Hash =
  result = hash cast[pointer](obj.pt)

proc toRef*[T: ref](obj: WeakRef[T]): T =
  result = cast[T](obj)

proc toRef*[T: ref](obj: T): T =
  result = obj

proc isolate*[T](obj: WeakRef[T]): Isolated[WeakRef[T]] =
  result = unsafeIsolate(obj)

proc `$`*[T](obj: WeakRef[T]): string =
  result = "Weak[" & $(T) & "]"
  result &= "(0x"
  result &= obj.toPtr().repr
  result &= ")"

type
  AgentObj = object of RootObj
    subscribers*: Table[SigilName, OrderedSet[Subscription]] ## agents listening to me
    subscribedTo*: HashSet[WeakRef[Agent]] ## agents I'm listening to

  Agent* = ref object of AgentObj

  Subscription* = object
    tgt*: WeakRef[Agent]
    slot*: AgentProc

  # Procedure signature accepted as an RPC call by server
  AgentProc* = proc(context: Agent, params: SigilParams) {.nimcall.}

  AgentProcTy*[S] = AgentProc

  Signal*[S] = AgentProcTy[S]
  SignalTypes* = distinct object

method removeSubscriptionsFor*(
    self: Agent, subscriber: WeakRef[Agent]
) {.base, gcsafe, raises: [].} =
  ## Route's an rpc request. 
  # echo "freeing subscribed: ", self.debugId
  var delSigs: seq[SigilName]
  var toDel: seq[Subscription]
  for signal, subscriptions in self.subscribers.mpairs():
    toDel.setLen(0)
    for subscription in subscriptions :
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

template unsubscribe*(subscribedTo: HashSet[WeakRef[Agent]], xid: WeakRef[Agent]) =
  ## unsubscribe myself from agents I'm subscribed (listening) to
  # echo "subscribed: ", xid[].subscribed.toSeq.mapIt(it[].debugId).repr
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

proc `=destroy`*(agent: AgentObj) =
  let xid: WeakRef[Agent] = WeakRef[Agent](pt: cast[Agent](addr agent))

  # echo "\ndestroy: agent: ", xid[].debugId, " pt: ", xid.toPtr.repr, " lstCnt: ", xid[].subscribers.len(), " subCnt: ", xid[].subscribed.len
  xid.toRef().subscribedTo.unsubscribe(xid)
  xid.toRef().subscribers.removeSubscription(xid)

  # xid[].subscribers.clear()
  `=destroy`(xid[].subscribers)
  `=destroy`(xid[].subscribedTo)

proc `$`*[T: Agent](obj: WeakRef[T]): string =
  result = $(T)
  result &= "{id: "
  result &= obj.getId().repr
  result &= "}"

when defined(nimscript):
  proc getId*(a: Agent): SigilId =
    a.debugId

  var lastUId {.compileTime.}: int = 1
else:
  proc getId*[T: Agent](a: WeakRef[T]): SigilId =
    cast[int](a.toPtr())

  proc getId*(a: Agent): SigilId =
    cast[int](cast[pointer](a))

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
  result = WeakRef[T](pt: obj)

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

    result = SigilResponse(kind: Response, id: req.origin, result: res)
