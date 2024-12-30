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

import std/[terminal, strutils, strformat, sequtils]
export strformat

var
  pcolors* = [fgRed, fgYellow, fgBlue, fgMagenta, fgCyan]
  pcnt*: int = 0
  pidx* {.threadVar.}: int
  plock: Lock

plock.initLock()

proc print*(msgs: varargs[string, `$`]) {.raises: [].} =
  {.cast(gcsafe).}:
    try:
      # withLock plock:
      block:
        let
          tid = getThreadId()
          color =
            if pidx == 0:
              fgGreen
            else:
              pcolors[pidx mod pcolors.len()]
        var msg = ""
        for m in msgs: msg &= m
        stdout.styledWriteLine color, msg, {styleBright}, &" [th: {$tid}]"
        stdout.flushFile()
    except IOError:
      discard

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

template removeSubscriptionsForImpl*(
    self: Agent, subscriber: WeakRef[Agent]
) =
  ## Route's an rpc request. 
  var delSigs: seq[SigilName]
  var toDel: seq[Subscription]
  for signal, subscriptions in self.subscribers.mpairs():
    print "removeSubscriptionsFor subs sig: ", $signal
    toDel.setLen(0)
    for subscription in subscriptions:
      if subscription.tgt == subscriber:
        toDel.add(subscription)
        # print "agentRemoved: ", "tgt: ", xid.toPtr.repr, " id: ", agent.debugId, " obj: ", obj[].debugId, " name: ", signal
    for subscription in toDel:
      subscriptions.excl(subscription)
    if subscriptions.len() == 0:
      delSigs.add(signal)
  for sig in delSigs:
    self.subscribers.del(sig)

method removeSubscriptionsFor*(
    self: Agent, subscriber: WeakRef[Agent]
) {.base, gcsafe, raises: [].} =
  print "removeSubscriptionsFor:agent: ", " self:id: ", $self.getId()
  removeSubscriptionsForImpl(self, subscriber)

template unregisterSubscriberImpl*(
    self: Agent, listener: WeakRef[Agent]
) =
  # print "\unregisterSubscriber: ", subscriber.tgt
  # print "\tlisterners:subscribed ", subscriber.tgt[].subscribed
  assert listener in self.subscribedTo
  self.subscribedTo.excl(listener)
  # print "\tlisterners:subscribed ", subscriber.tgt[].subscribed

method unregisterSubscriber*(
    self: Agent, listener: WeakRef[Agent]
) {.base, gcsafe, raises: [].} =
  print &"unregisterSubscriber:agent: self: {$self.getId()}"
  assert listener in self.subscribedTo
  self.subscribedTo.excl(listener)

proc unsubscribe*(subscribedTo: HashSet[WeakRef[Agent]], xid: WeakRef[Agent]) =
  ## unsubscribe myself from agents I'm subscribed (listening) to
  print &"unsubscribe: {$subscribedTo.len()}"
  for obj in subscribedTo:
    obj[].removeSubscriptionsFor(xid)

template removeSubscription*(
    subscribers: Table[SigilName, OrderedSet[Subscription]], xid: WeakRef[Agent]
) =
  ## remove myself from agents listening to me
  for signal, subscriptions in subscribers.pairs():
    # echo "freeing signal: ", signal, " subscribers: ", subscriberPairs
    for subscription in subscriptions:
      subscription.tgt[].unregisterSubscriber(xid)

proc `=destroy`*(agent: AgentObj) {.forbids: [DestructorUnsafe].} =
  let xid: WeakRef[Agent] = WeakRef[Agent](pt: cast[pointer](addr agent))

  print &"destroy: agent: ",
          &" pt: {xid.toPtr.repr}",
          &" freed: {agent.freed}",
          &" subs: {xid[].subscribers.len()}",
          &" subTo: {xid[].subscribedTo.len()}"
  print "destroy agent: ", getStackTrace().replace("\n", "\n\t")
  when defined(debug):
    if agent.freed:
      raise newException(Defect, "already freed!")
    xid[].freed = true

  agent.subscribedTo.unsubscribe(xid)
  agent.subscribers.removeSubscription(xid)

  `=destroy`(xid[].subscribers)
  `=destroy`(xid[].subscribedTo)
  print "finished destroy: agent: ", " pt: ", xid.toPtr.repr

proc `$`*[T: Agent](obj: WeakRef[T]): string =
  result = $(T)
  result &= "{id: "
  result &= $obj.getId()
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
