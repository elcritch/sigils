import std/[options, tables, sequtils, sets, macros, hashes]
import std/times
import std/isolation
import std/[locks, options]
import stack_strings

import protocol
import weakrefs

when (NimMajor, NimMinor, NimPatch) < (2, 2, 0):
  {.passc:"-fpermissive".}
  {.passl:"-fpermissive".}


when defined(nimscript):
  import std/json
  import ../runtime/jsonutils_lite
  export json
elif defined(useJsonSerde):
  import std/json
  import std/jsonutils
  export json
else:
  import svariant

export sets
export options
export svariant

export IndexableChars
export weakrefs
export protocol

import std/[terminal, strutils, strformat, sequtils]
export strformat

var
  pcolors* = [fgRed, fgYellow, fgMagenta, fgCyan]
  pcnt*: int = 0
  pidx* {.threadVar.}: int
  plock: Lock
  debugPrintQuiet* = false

plock.initLock()

proc debugPrintImpl*(msgs: varargs[string, `$`]) {.raises: [].} =
  {.cast(gcsafe).}:
    try:
      # withLock plock:
      block:
        let
          tid = getThreadId()
          color =
            if pidx == 0:
              fgBlue
            else:
              pcolors[pidx mod pcolors.len()]
        var msg = ""
        for m in msgs:
          msg &= m
        stdout.styledWriteLine color, msg, {styleBright}, &" [th: {$tid}]"
        stdout.flushFile()
    except IOError:
      discard

template debugPrint*(msgs: varargs[untyped]) =
  when defined(sigilsDebugPrint):
    if not debugPrintQuiet:
      debugPrintImpl(msgs)

proc brightPrint*(color: ForegroundColor, msg, value: string, msg2 = "", value2 = "") =
  if not debugPrintQuiet:
    stdout.styledWriteLine color,
      msg,
      {styleBright, styleItalic},
      value,
      resetStyle,
      color,
      msg2,
      {styleBright, styleItalic},
      value2

proc brightPrint*(msg, value: string, msg2 = "", value2 = "") =
  brightPrint(fgGreen, msg, value, msg2, value2)

type
  AgentObj = object of RootObj
    subcriptions*: seq[tuple[signal: SigilName, subscription: Subscription]]
      ## agents listening to me
    listening*: HashSet[WeakRef[Agent]] ## agents I'm listening to
    when defined(sigilsDebug) or defined(debug) or defined(sigilsDebugPrint):
      freedByThread*: int
    when defined(sigilsDebug):
      debugName*: string

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
  proc getSigilId*(a: Agent): SigilId =
    a.debugId

  var lastUId {.compileTime.}: int = 1
else:
  proc getSigilId*[T: Agent](a: WeakRef[T]): SigilId =
    cast[SigilId](a.toPtr())

  proc getSigilId*(a: Agent): SigilId =
    cast[SigilId](cast[pointer](a))

proc `$`*[T: Agent](obj: WeakRef[T]): string =
  result = "Weak["
  when defined(sigilsDebug):
    if obj.isNil:
      result &= "nil"
    else:
      result &= obj[].debugName
    result &= "; "
  result &= $(T)
  result &= "]"
  result &= "(0x"
  if obj.isNil:
    result &= "nil"
  else:
    result &= obj.toPtr().repr
  result &= ")"

template removeSubscriptionsForImpl*(self: Agent, subscriber: WeakRef[Agent]) =
  ## Route's an rpc request. 
  var toDel: seq[int] = newSeq[int](self.subcriptions.len())
  for idx in countdown(self.subcriptions.len() - 1, 0):
    debugPrint "   removeSubscriptionsFor subs sig: ", $self.subcriptions[idx].signal
    if self.subcriptions[idx].subscription.tgt == subscriber:
      self.subcriptions.delete(idx..idx)

method removeSubscriptionsFor*(
    self: Agent, subscriber: WeakRef[Agent], slot: AgentProc
) {.base, gcsafe, raises: [].} =
  debugPrint "   removeSubscriptionsFor:agent: ", " self:id: ", $self.unsafeWeakRef()
  removeSubscriptionsForImpl(self, subscriber)

template unregisterSubscriberImpl*(self: Agent, listener: WeakRef[Agent]) =
  debugPrint "\tunregisterSubscriber: ", $listener, " from self: ", self.unsafeWeakRef()
  # debugPrint "\tlisterners:subscribed ", subscriber.tgt[].subscribed
  assert listener in self.listening
  self.listening.excl(listener)

method unregisterSubscriber*(
    self: Agent, listener: WeakRef[Agent]
) {.base, gcsafe, raises: [].} =
  debugPrint &"   unregisterSubscriber:agent: self: {$self.unsafeWeakRef()}"
  unregisterSubscriberImpl(self, listener)

template unsubscribeFrom*(self: WeakRef[Agent], listening: HashSet[WeakRef[Agent]]) =
  ## unsubscribe myself from agents I'm subscribed (listening) to
  debugPrint "   unsubscribeFrom:cnt: ", $listening.len(), " self: {$self}"
  for agent in listening:
    agent[].removeSubscriptionsFor(self, nil)

template removeSubscriptions*(
    agent: WeakRef[Agent], subcriptions: seq[tuple[signal: SigilName, subscription: Subscription]]
) =
  ## remove myself from agents listening to me
  var tgts: HashSet[WeakRef[Agent]] = initHashSet[WeakRef[Agent]](subcriptions.len())
  for idx in 0 ..< subcriptions.len():
    tgts.incl(subcriptions[idx].subscription.tgt)

  for tgt in tgts:
    tgt[].unregisterSubscriber(agent)

proc destroyAgent*(agentObj: AgentObj) {.forbids: [DestructorUnsafe].} =
  let agent: WeakRef[Agent] = unsafeWeakRef(cast[Agent](addr(agentObj)))

  debugPrint &"destroy: agent: ",
    &" pt: {$agent}",
    &" freedByThread: {agentObj.freedByThread}",
    &" subs: {agent[].subcriptions.len()}",
    &" subTo: {agent[].listening.len()}"
  # debugPrint "destroy agent: ", getStackTrace().replace("\n", "\n\t")
  when defined(debug) or defined(sigilsDebug):
    assert agentObj.freedByThread == 0
    agent[].freedByThread = getThreadId()

  agent.removeSubscriptions(agentObj.subcriptions)
  agent.unsubscribeFrom(agentObj.listening)

  `=destroy`(agent[].subcriptions)
  `=destroy`(agent[].listening)
  debugPrint "\tfinished destroy: agent: ", " pt: ", $agent
  when defined(sigilsDebug):
    `=destroy`(agent[].debugName)

proc `=destroy`*(agentObj: AgentObj) {.forbids: [DestructorUnsafe].} =
  destroyAgent(agentObj)

template toAgentObj*[T: Agent](agent: T): AgentObj =
  Agent(agent)[]

proc hash*(a: Agent): Hash =
  hash(a.getSigilId())

method hasConnections*(self: Agent): bool {.base, gcsafe, raises: [].} =
  self.subcriptions.len() != 0 or self.listening.len() != 0

iterator getSubscriptions*(obj: Agent, sig: SigilName): var Subscription =
  for item in obj.subcriptions.mitems():
    if item.signal == sig or item.signal == AnySigilName:
      yield item.subscription

iterator getSubscriptions*(obj: WeakRef[Agent], sig: SigilName): var Subscription =
  for item in obj[].subcriptions.mitems():
    if item.signal == sig or item.signal == AnySigilName:
      yield item.subscription

proc asAgent*[T: Agent](obj: WeakRef[T]): WeakRef[Agent] =
  result = WeakRef[Agent](pt: obj.pt)

proc asAgent*[T: Agent](obj: T): Agent =
  result = obj

proc hasSubscription*(obj: Agent, sig: SigilName): bool =
  for idx in 0 ..< obj.subcriptions.len():
    if obj.subcriptions[idx].signal == sig:
      return true

proc hasSubscription*(obj: Agent, sig: SigilName, tgt: Agent | WeakRef[Agent]): bool =
  let tgt = tgt.unsafeWeakRef().toKind(Agent)
  for idx in 0 ..< obj.subcriptions.len():
    if obj.subcriptions[idx].signal == sig and
        obj.subcriptions[idx].subscription.tgt == tgt:
      return true

proc hasSubscription*(obj: Agent, sig: SigilName, tgt: Agent | WeakRef[Agent], slot: AgentProc): bool =
  let tgt = tgt.unsafeWeakRef().toKind(Agent)
  for idx in 0 ..< obj.subcriptions.len():
    if obj.subcriptions[idx].signal == sig and
        obj.subcriptions[idx].subscription.tgt == tgt and
        obj.subcriptions[idx].subscription.slot == slot:
      return true

proc addSubscription*(
    obj: Agent, sig: SigilName, tgt: Agent | WeakRef[Agent], slot: AgentProc
): void =
  doAssert not obj.isNil(), "agent is nil!"
  assert slot != nil

  if not obj.hasSubscription(sig, tgt, slot):
    obj.subcriptions.add((sig, Subscription(tgt: tgt.unsafeWeakRef().asAgent(), slot: slot)))
    tgt.listening.incl(obj.unsafeWeakRef().asAgent())

template addSubscription*(
    obj: Agent, sig: IndexableChars, tgt: Agent | WeakRef[Agent], slot: AgentProc
): void =
  addSubscription(obj, sig.toSigilName(), tgt, slot)

var printConnectionsSlotNames* = initTable[pointer, string]()

proc delSubscription*(
    self: Agent, sig: SigilName, tgt: Agent | WeakRef[Agent], slot: AgentProc
): void =

  let tgt = tgt.unsafeWeakRef().toKind(Agent)

  var
   subsFound: int
   subsDeleted: int

  for idx in countdown(self.subcriptions.len() - 1, 0):
    if self.subcriptions[idx].signal == sig and
        self.subcriptions[idx].subscription.tgt == tgt:
      subsFound.inc()
      if slot == nil or self.subcriptions[idx].subscription.slot == slot:
        subsDeleted.inc()
        self.subcriptions.delete(idx..idx)

  if subsFound == subsDeleted:
    tgt[].listening.excl(self.unsafeWeakRef())

template delSubscription*(
    obj: Agent, sig: IndexableChars, tgt: Agent | WeakRef[Agent], slot: AgentProc
): void =
  delSubscription(obj, sig.toSigilName(), tgt, slot)

proc printConnections*(agent: Agent) =
  withLock plock:
    if agent.isNil:
      brightPrint fgBlue, "connections for Agent: ", "nil"
      return
    when defined(sigilsDebug):
      if agent[].freedByThread != 0:
        brightPrint fgBlue,
          "connections for Agent: ",
          $agent.unsafeWeakRef(),
          " freedByThread: ",
          $agent[].freedByThread
        return
    brightPrint fgBlue, "connections for Agent: ", $agent.unsafeWeakRef()
    brightPrint fgMagenta, "\t subscribers:", ""
    for item in agent.subcriptions:
      let sname = printConnectionsSlotNames.getOrDefault(item.subscription.slot, item.subscription.slot.repr)
      brightPrint fgGreen, "\t\t:", $item.signal, ": => ", $item.subscription.tgt & " slot: " & $sname
    brightPrint fgMagenta, "\t listening:", ""
    for listening in agent.listening:
      brightPrint fgRed, "\t\t listen: ", $listening
