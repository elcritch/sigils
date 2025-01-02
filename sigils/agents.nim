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
  pcolors* = [fgRed, fgYellow, fgMagenta, fgCyan]
  pcnt*: int = 0
  pidx* {.threadVar.}: int
  plock: Lock

plock.initLock()

proc debugPrintImpl*(msgs: varargs[string, `$`]) {.raises: [].} =
  {.cast(gcsafe).}:
      try:
        withLock plock:
        # block:
          let
            tid = getThreadId()
            color =
              if pidx == 0:
                fgBlue
              else:
                pcolors[pidx mod pcolors.len()]
          var msg = ""
          for m in msgs: msg &= m
          stdout.styledWriteLine color, msg, {styleBright}, &" [th: {$tid}]"
          stdout.flushFile()
      except IOError:
        discard

template debugPrint*(msgs: varargs[untyped]) =
  when defined(sigilsDebugPrint):
    debugPrintImpl(msgs)

type
  AgentObj = object of RootObj
    suscriptionsTable*: Table[SigilName, OrderedSet[Subscription]] ## agents listening to me
    listening*: HashSet[WeakRef[Agent]] ## agents I'm listening to
    when defined(sigilDebugFreed) or defined(debug):
      freedByThread*: int

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
  for signal, subscriptions in self.suscriptionsTable.mpairs():
    debugPrint "removeSubscriptionsFor subs sig: ", $signal
    toDel.setLen(0)
    for subscription in subscriptions:
      if subscription.tgt == subscriber:
        toDel.add(subscription)
        # debugPrint "agentRemoved: ", "tgt: ", xid.toPtr.repr, " id: ", agent.debugId, " obj: ", obj[].debugId, " name: ", signal
    for subscription in toDel:
      subscriptions.excl(subscription)
    if subscriptions.len() == 0:
      delSigs.add(signal)
  for sig in delSigs:
    self.suscriptionsTable.del(sig)

method removeSubscriptionsFor*(
    self: Agent, subscriber: WeakRef[Agent]
) {.base, gcsafe, raises: [].} =
  debugPrint "removeSubscriptionsFor:agent: ", " self:id: ", $self.getId()
  removeSubscriptionsForImpl(self, subscriber)

template unregisterSubscriberImpl*(
    self: Agent, listener: WeakRef[Agent]
) =
  # debugPrint "\unregisterSubscriber: ", subscriber.tgt
  # debugPrint "\tlisterners:subscribed ", subscriber.tgt[].subscribed
  assert listener in self.listening
  self.listening.excl(listener)
  # debugPrint "\tlisterners:subscribed ", subscriber.tgt[].subscribed

method unregisterSubscriber*(
    self: Agent, listener: WeakRef[Agent]
) {.base, gcsafe, raises: [].} =
  debugPrint &"unregisterSubscriber:agent: self: {$self.getId()}"
  unregisterSubscriberImpl(self, listener)

proc unsubscribe*(listening: HashSet[WeakRef[Agent]], xid: WeakRef[Agent]) =
  ## unsubscribe myself from agents I'm subscribed (listening) to
  debugPrint &"unsubscribe: {$listening.len()}"
  for obj in listening:
    obj[].removeSubscriptionsFor(xid)

template removeSubscription*(
    suscriptionsTable: Table[SigilName, OrderedSet[Subscription]], xid: WeakRef[Agent]
) =
  ## remove myself from agents listening to me
  for signal, subscriptions in suscriptionsTable.pairs():
    # echo "freeing signal: ", signal, " suscriptionsTable: ", subscriberPairs
    for subscription in subscriptions:
      subscription.tgt[].unregisterSubscriber(xid)

proc `=destroy`*(agentObj: AgentObj) {.forbids: [DestructorUnsafe].} =
  when defined(sigilsWeakRefCursor):
    let xid: WeakRef[Agent] = WeakRef[Agent](pt: cast[Agent](addr agentObj))
  else:
    let xid: WeakRef[Agent] = WeakRef[Agent](pt: cast[pointer](addr agentObj))

  debugPrint &"destroy: agent: ",
          &" pt: 0x{xid.toPtr.repr}",
          &" freed: {agentObj.freedByThread}",
          &" subs: {xid[].suscriptionsTable.len()}",
          &" subTo: {xid[].listening.len()}"
  # debugPrint "destroy agent: ", getStackTrace().replace("\n", "\n\t")
  when defined(debug) or defined(sigilDebugFreed):
    assert agentObj.freedByThread == 0
    xid[].freedByThread = getThreadId()

  agentObj.listening.unsubscribe(xid)
  agentObj.suscriptionsTable.removeSubscription(xid)

  `=destroy`(xid[].suscriptionsTable)
  `=destroy`(xid[].listening)
  debugPrint "finished destroy: agent: ", " pt: 0x", xid.toPtr.repr

template toAgentObj*[T: Agent](agent: T): AgentObj =
  Agent(agent)[]

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
  # echo "FIND:suscriptionsTable: ", obj.suscriptionsTable
  if obj.suscriptionsTable.hasKey(sig):
    result = obj.suscriptionsTable[sig]
  elif obj.suscriptionsTable.hasKey(AnySigilName):
    result = obj.suscriptionsTable[AnySigilName]

template getSubscriptions*(
    obj: Agent, sig: string
): OrderedSet[(WeakRef[Agent], AgentProc)] =
  obj.getSubscriptions(sig)

proc asAgent*[T: Agent](obj: WeakRef[T]): WeakRef[Agent] =
  result = WeakRef[Agent](pt: obj.pt)

proc asAgent*[T: Agent](obj: T): Agent =
  result = obj

proc addSubscription*(obj: Agent, sig: SigilName, tgt: Agent | WeakRef[Agent], slot: AgentProc): void =
  # echo "add agent listener: ", sig, " obj: ", obj.debugId, " tgt: ", tgt.debugId
  # if obj.suscriptionsTable.hasKey(sig):
  #   echo "listener:count: ", obj.suscriptionsTable[sig].len()
  assert slot != nil

  obj.suscriptionsTable.withValue(sig, subs):
    # if (tgt.unsafeWeakRef(), slot,) notin agents[]:
    #   echo "addAgentsubscribers: ", "tgt: 0x", tgt.unsafeWeakRef().toPtr().pointer.repr, " id: ", tgt.debugId, " obj: ", obj.debugId, " name: ", sig
    subs[].incl(Subscription(tgt: tgt.unsafeWeakRef().asAgent(), slot: slot))
  do:
    # echo "addAgentsubscribers: ", "tgt: 0x", tgt.unsafeWeakRef().toPtr().pointer.repr, " id: ", tgt.debugId, " obj: ", obj.debugId, " name: ", sig
    var subs = initOrderedSet[Subscription]()
    subs.incl(Subscription(tgt: tgt.unsafeWeakRef().asAgent(), slot: slot))
    obj.suscriptionsTable[sig] = ensureMove subs

  tgt.listening.incl(obj.unsafeWeakRef().asAgent())
  # echo "suscriptionsTable: ", obj.suscriptionsTable.len, " SUBSC: ", tgt.subscribed.len

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
