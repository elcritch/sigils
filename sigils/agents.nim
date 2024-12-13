import std/[options, tables, sets, macros, hashes]
import std/times

import protocol

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

proc `$`*[T](obj: WeakRef[T]): string =
  result = $(T)
  result &= "("
  result &= obj.toPtr().repr
  result &= ")"

type
  AgentObj = object of RootObj
    subscribers*: Table[string, OrderedSet[AgentPairing]] ## agents listening to me
    subscribedTo*: HashSet[WeakRef[Agent]] ## agents I'm listening to

  Agent* = ref object of AgentObj

  AgentPairing* = tuple[tgt: WeakRef[Agent], fn: AgentProc]

  # Procedure signature accepted as an RPC call by server
  AgentProc* = proc(context: Agent, params: SigilParams) {.nimcall.}

  AgentProcTy*[S] = AgentProc

  Signal*[S] = AgentProcTy[S]
  SignalTypes* = distinct object

proc unsubscribe(subscribedTo: HashSet[WeakRef[Agent]], xid: WeakRef[Agent]) =
  ## remove myself from agents I'm subscribed to
  # echo "subscribed: ", xid[].subscribed.toSeq.mapIt(it[].debugId).repr
  var delSigs: seq[string]
  var toDel: seq[AgentPairing]
  for obj in subscribedTo:
    # echo "freeing subscribed: ", obj[].debugId
    delSigs.setLen(0)
    for signal, subscriberPairs in obj[].subscribers.mpairs():
      toDel.setLen(0)
      for item in subscriberPairs:
        if item.tgt == xid:
          toDel.add(item)
          # echo "agentRemoved: ", "tgt: ", xid.toPtr.repr, " id: ", agent.debugId, " obj: ", obj[].debugId, " name: ", signal
      for item in toDel:
        subscriberPairs.excl(item)
      if subscriberPairs.len() == 0:
        delSigs.add(signal)
    for sig in delSigs:
      obj[].subscribers.del(sig)

proc remove(
    subscribers: var Table[string, OrderedSet[AgentPairing]], xid: WeakRef[Agent]
) =
  ## remove myself from agents listening to me
  for signal, subscriberPairs in subscribers.mpairs():
    # echo "freeing signal: ", signal, " subscribers: ", subscriberPairs
    for subscriber in subscriberPairs:
      # echo "\tlisterners: ", subscriber.tgt
      # echo "\tlisterners:subscribed ", subscriber.tgt[].subscribed
      subscriber.tgt[].subscribedTo.excl(xid)
      # echo "\tlisterners:subscribed ", subscriber.tgt[].subscribed

proc `=destroy`*(agent: AgentObj) =
  let xid: WeakRef[Agent] = WeakRef[Agent](pt: cast[Agent](addr agent))

  # echo "\ndestroy: agent: ", xid[].debugId, " pt: ", xid.toPtr.repr, " lstCnt: ", xid[].subscribers.len(), " subCnt: ", xid[].subscribed.len
  xid.toRef().subscribedTo.unsubscribe(xid)
  xid.toRef().subscribers.remove(xid)

  # xid[].subscribers.clear()
  `=destroy`(xid[].subscribers)
  `=destroy`(xid[].subscribedTo)

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

proc getAgentListeners*(
    obj: Agent, sig: string
): OrderedSet[(WeakRef[Agent], AgentProc)] =
  # echo "FIND:subscribers: ", obj.subscribers
  if obj.subscribers.hasKey(sig):
    result = obj.subscribers[sig]

proc unsafeWeakRef*[T: Agent](obj: T): WeakRef[T] =
  result = WeakRef[T](pt: obj)

proc asAgent*[T: Agent](obj: WeakRef[T]): WeakRef[Agent] =
  result = WeakRef[Agent](pt: obj.pt)

proc asAgent*[T: Agent](obj: T): Agent =
  result = obj

proc addAgentListeners*(obj: Agent, sig: string, tgt: Agent, slot: AgentProc): void =
  # echo "add agent listener: ", sig, " obj: ", obj.debugId, " tgt: ", tgt.debugId
  # if obj.subscribers.hasKey(sig):
  #   echo "listener:count: ", obj.subscribers[sig].len()
  assert slot != nil

  obj.subscribers.withValue(sig, agents):
    # if (tgt.unsafeWeakRef(), slot,) notin agents[]:
    #   echo "addAgentsubscribers: ", "tgt: ", tgt.unsafeWeakRef().toPtr().pointer.repr, " id: ", tgt.debugId, " obj: ", obj.debugId, " name: ", sig
    agents[].incl((tgt.unsafeWeakRef(), slot))
  do:
    # echo "addAgentsubscribers: ", "tgt: ", tgt.unsafeWeakRef().toPtr().pointer.repr, " id: ", tgt.debugId, " obj: ", obj.debugId, " name: ", sig
    var agents = initOrderedSet[AgentPairing]()
    agents.incl((tgt.unsafeWeakRef(), slot))
    obj.subscribers[sig] = ensureMove agents

  tgt.subscribedTo.incl(obj.unsafeWeakRef())
  # echo "subscribers: ", obj.subscribers.len, " SUBSC: ", tgt.subscribed.len

method callMethod*(
    ctx: Agent, req: SigilRequest, slot: AgentProc
): SigilResponse {.base, gcsafe, effectsOf: slot.} =
  ## Route's an rpc request. 

  if slot.isNil:
    let msg = req.procName & " is not a registered RPC method."
    let err = SigilError(code: METHOD_NOT_FOUND, msg: msg)
    result = wrapResponseError(req.origin, err)
  else:
    slot(ctx, req.params)
    let res = rpcPack(true)

    result = SigilResponse(kind: Response, id: req.origin, result: res)
