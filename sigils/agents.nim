
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

type
  WeakRef*[T] = object
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
    debugId*: int = 0
    subscribers*: Table[string, OrderedSet[AgentPairing]] ## agents listening to me
    subscribedTo*: HashSet[WeakRef[Agent]] ## agents I'm listening to

  Agent* = ref object of AgentObj

  AgentPairing* = tuple[tgt: WeakRef[Agent], fn: AgentProc]

  # Context for servicing an RPC call 
  RpcContext* = Agent

  # Procedure signature accepted as an RPC call by server
  AgentProc* = proc(context: RpcContext,
                    params: RpcParams,
                    ) {.nimcall.}

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

proc remove(subscribers: var Table[string, OrderedSet[AgentPairing]], xid: WeakRef[Agent]) =
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

## TODO: figure out if we need debugId at all?
when defined(nimscript):
  proc getId*(a: Agent): AgentId = a.debugId
  # proc getAgentProcId*(a: AgentProc): int = cast[int](cast[pointer](a))
  var lastUId {.compileTime.}: int = 1
else:
  proc getId*[T: Agent](a: WeakRef[T]): AgentId = cast[int](a.toPtr())
  proc getId*(a: Agent): AgentId = cast[int](cast[pointer](a))
  # proc getAgentProcId*(a: AgentProc): int = cast[int](cast[pointer](a))
  var lastUId: int = 0

proc nextAgentId*(): int =
  lastUId.inc()
  lastUId

proc new*[T: Agent](tp: typedesc[T]): T =
  result = T()
  result.debugId = nextAgentId()

proc hash*(a: Agent): Hash = hash(a.getId())
# proc hash*(a: AgentProc): Hash = hash(getAgentProcId(a))

type

  ConversionError* = object of CatchableError
  AgentSlotError* = object of CatchableError

  AgentErrorStackTrace* = object
    code*: int
    msg*: string
    stacktrace*: seq[string]

  AgentBindError* = object of ValueError
  AgentAddressUnresolvableError* = object of ValueError

proc pack*[T](ss: var Variant, val: T) =
  # echo "Pack Type: ", getTypeId(T), " <- ", typeof(val)
  ss = newVariant(val)

proc unpack*[T](ss: Variant, obj: var T) =
  # if ss.ofType(T):
    obj = ss.get(T)
  # else:
    # raise newException(ConversionError, "couldn't convert to: " & $(T))

proc rpcPack*(res: RpcParams): RpcParams {.inline.} =
  result = res

proc rpcPack*[T](res: T): RpcParams =
  when defined(nimscript) or defined(useJsonSerde):
    let jn = toJson(res)
    result = RpcParams(buf: jn)
  else:
    result = RpcParams(buf: newVariant(res))

proc rpcUnpack*[T](obj: var T, ss: RpcParams) =
  # try:
    when defined(nimscript) or defined(useJsonSerde):
      obj.fromJson(ss.buf)
      discard
    else:
      ss.buf.unpack(obj)
  # except ConversionError as err:
  #   raise newException(ConversionError,
  #                      "unable to parse parameters: " & err.msg & " res: " & $repr(ss.buf))
  # except AssertionDefect as err:
  #   raise newException(ConversionError,
  #                      "unable to parse parameters: " & err.msg)

proc initAgentRequest*[S, T](
  procName: string,
  args: T,
  id: AgentId = AgentId(-1),
  reqKind: AgentType = Request,
): AgentRequestTy[S] =
  # echo "AgentRequest: ", procName, " args: ", args.repr
  result = AgentRequestTy[S](
    kind: reqKind,
    id: id,
    procName: procName,
    params: rpcPack(args)
  )

proc getAgentListeners*(obj: Agent,
                        sig: string
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

proc addAgentListeners*(obj: Agent,
                        sig: string,
                        tgt: Agent,
                        slot: AgentProc
                        ): void =

  # echo "add agent listener: ", sig, " obj: ", obj.debugId, " tgt: ", tgt.debugId
  # if obj.subscribers.hasKey(sig):
  #   echo "listener:count: ", obj.subscribers[sig].len()
  assert slot != nil

  obj.subscribers.withValue(sig, agents):
    # if (tgt.unsafeWeakRef(), slot,) notin agents[]:
    #   echo "addAgentsubscribers: ", "tgt: ", tgt.unsafeWeakRef().toPtr().pointer.repr, " id: ", tgt.debugId, " obj: ", obj.debugId, " name: ", sig
    agents[].incl((tgt.unsafeWeakRef(), slot,))
  do:
    # echo "addAgentsubscribers: ", "tgt: ", tgt.unsafeWeakRef().toPtr().pointer.repr, " id: ", tgt.debugId, " obj: ", obj.debugId, " name: ", sig
    var agents = initOrderedSet[AgentPairing]()
    agents.incl( (tgt.unsafeWeakRef(), slot,) )
    obj.subscribers[sig] = ensureMove agents

  tgt.subscribedTo.incl(obj.unsafeWeakRef())
  # echo "subscribers: ", obj.subscribers.len, " SUBSC: ", tgt.subscribed.len
