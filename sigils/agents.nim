import std/[hashes, options, sets, strformat, tables]
import stack_strings

import protocol
import hybridTables
import weakrefs
import debugs

when (NimMajor, NimMinor, NimPatch) < (2, 2, 0):
  {.passc: "-fpermissive".}
  {.passl: "-fpermissive".}

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

export sets, options, svariant, IndexableChars, weakrefs, protocol

when defined(sigilsDebugPrint):
  import std/terminal
export strformat
export debugs

const
  sigilsClosuresEnabled* = defined(sigilsClosures)
  sigilsSlotEnvEnabled* =
    sigilsClosuresEnabled or defined(sigilsSlotEnv)
  sigilsSlotEnvDisabled* =
    (not sigilsSlotEnvEnabled) or defined(sigilsNoSlotEnv) or
    defined(sigilsNoClosureSlotEnv)
  sigilsSubscriptionBinarySearchThreshold {.intdefine.} = 16

type
  AgentProc* = proc(context: Agent, params: SigilParams) {.nimcall.}
  LocalAgentProc* = proc(context: Agent, params: pointer) {.nimcall.}

  SigilLocalCall*[S, A] = object
    source*: S
    procName*: SigilName
    origin*: SigilId
    args*: A

  SlotEnv* = ref object of RootObj
    ## Owned environment for receiver-bound closure slots.

  EnvAgentProc* = proc(
    context: Agent, params: SigilParams, env: SlotEnv
  ) {.nimcall.}

  Subscription* = object
    tgt*: WeakRef[Agent]
    packedSlot*: AgentProc
    directSlot*: LocalAgentProc
    when not sigilsSlotEnvDisabled:
      envSlot*: EnvAgentProc
      env*: SlotEnv

  SubscriptionStore* =
    HybridSigilTable[Subscription, sigilsSubscriptionBinarySearchThreshold]

  AgentObj = object of RootObj
    subcriptions*: SubscriptionStore
      ## agents listening to me
    listening*: HashSet[WeakRef[Agent]] ## agents I'm listening to
    when defined(sigilsDebug) or defined(debug) or defined(sigilsDebugPrint):
      freedByThread*: int
    when defined(sigilsDebug):
      debugName*: string

  Agent* = ref object of AgentObj

  AgentProcTy*[S] = AgentProc
  LocalAgentProcTy*[S] = LocalAgentProc

  Signal*[S] = AgentProcTy[S]
  SignalTypes* = distinct object
  LocalSignalTypes* = distinct object

type SubscriptionEntry* = tuple[signal: SigilName, subscription: Subscription]

func len*(store: SubscriptionStore): int {.inline.} =
  hybridTables.len(store)

iterator items*(store: SubscriptionStore): SubscriptionEntry =
  for item in hybridTables.items(store):
    yield (signal: item.key, subscription: item.value)

proc `[]`*(store: SubscriptionStore, index: int): SubscriptionEntry =
  let item = hybridTables.`[]`(store, index)
  (signal: item.key, subscription: item.value)

proc setLen*(store: var SubscriptionStore, newLen: Natural) {.gcsafe,
    raises: [].} =
  hybridTables.setLen(store, newLen)

proc clear*(store: var SubscriptionStore) {.gcsafe, raises: [].} =
  hybridTables.clear(store)

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

method removeSubscriptionsFor*(
    self: Agent, subscriber: WeakRef[Agent]
) {.base, gcsafe, raises: [].} =
  debugPrint "   removeSubscriptionsFor:agent: ", " self:id: ",
      $self.unsafeWeakRef()
  ## Route's an rpc request.
  discard self.subcriptions.removeValues do(
      subscription: Subscription
  ) -> HybridRemoveAction:
    if subscription.tgt == subscriber:
      hraDelete
    else:
      hraKeep

method unregisterSubscriber*(
    self: Agent, listener: WeakRef[Agent]
) {.base, gcsafe, raises: [].} =
  debugPrint "\tunregisterSubscriber: ", $listener, " from self: ",
      self.unsafeWeakRef()
  debugPrint &"   unregisterSubscriber:agent: self: {$self.unsafeWeakRef()}"
  assert listener in self.listening
  self.listening.excl(listener)

template unsubscribeFrom*(self: WeakRef[Agent], listening: HashSet[WeakRef[Agent]]) =
  ## unsubscribe myself from agents I'm subscribed (listening) to
  debugPrint "   unsubscribeFrom:cnt: ", $listening.len(), " self: {$self}"
  for agent in listening:
    agent[].removeSubscriptionsFor(self)

template removeSubscriptions*(agent: WeakRef[Agent],
    subcriptions: SubscriptionStore) =
  ## remove myself from agents listening to me
  var tgts: HashSet[WeakRef[Agent]] = initHashSet[WeakRef[Agent]](
      subcriptions.len())
  for item in subcriptions:
    tgts.incl(item.subscription.tgt)

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
  if sig == AnySigilName:
    for sub in obj.subcriptions.valuesForKey(sig):
      yield sub
  elif compareSigilName(AnySigilName, sig) <= 0:
    for sub in obj.subcriptions.valuesForKey(AnySigilName):
      yield sub
    for sub in obj.subcriptions.valuesForKey(sig):
      yield sub
  else:
    for sub in obj.subcriptions.valuesForKey(sig):
      yield sub
    for sub in obj.subcriptions.valuesForKey(AnySigilName):
      yield sub

iterator getSubscriptions*(obj: WeakRef[Agent],
                           sig: SigilName): var Subscription =
  for sub in obj[].getSubscriptions(sig):
    yield sub

proc asAgent*[T: Agent](obj: WeakRef[T]): WeakRef[Agent] =
  result = WeakRef[Agent](pt: obj.pt)

proc asAgent*[T: Agent](obj: T): Agent =
  result = obj

method hasSubscription*(
    obj: Agent, sig: SigilName
): bool {.base, gcsafe, raises: [].} =
  obj.subcriptions.containsKey(sig)

method hasSubscription*(
    obj: Agent, sig: SigilName, tgt: WeakRef[Agent]
): bool {.base, gcsafe, raises: [].} =
  result = obj.subcriptions.containsValue(sig) do(
      subscription: Subscription
  ) -> bool:
    subscription.tgt == tgt

template hasSubscription*(obj: Agent, sig: SigilName, tgt: Agent): bool =
  let tgtRef = tgt.unsafeWeakRef().toKind(Agent)
  hasSubscription(obj, sig, tgtRef)

method hasSubscription*(
    obj: Agent, sig: SigilName, tgt: WeakRef[Agent], slot: AgentProc
): bool {.base, gcsafe, raises: [].} =
  result = obj.subcriptions.containsValue(sig) do(
      subscription: Subscription
  ) -> bool:
    subscription.tgt == tgt and subscription.packedSlot == slot

template hasSubscription*(obj: Agent,
                          sig: SigilName,
                          tgt: Agent,
                          slot: AgentProc): bool =
  let tgtRef = tgt.unsafeWeakRef().toKind(Agent)
  hasSubscription(obj, sig, tgtRef, slot)

proc hasCallable(subscription: Subscription): bool =
  when sigilsSlotEnvDisabled:
    not subscription.packedSlot.isNil or not subscription.directSlot.isNil
  else:
    not subscription.packedSlot.isNil or not subscription.directSlot.isNil or
      not subscription.envSlot.isNil

proc sameHandler(a, b: Subscription): bool =
  if a.packedSlot.isNil and b.packedSlot.isNil:
    result = a.directSlot == b.directSlot
  else:
    result = a.packedSlot == b.packedSlot
  when not sigilsSlotEnvDisabled:
    result = result and a.envSlot == b.envSlot and a.env == b.env

proc sameSubscription(a, b: Subscription): bool =
  a.tgt == b.tgt and sameHandler(a, b)

method hasSubscription*(
    obj: Agent, sig: SigilName, subscription: Subscription
): bool {.base, gcsafe, raises: [].} =
  result = obj.subcriptions.containsValue(sig) do(item: Subscription) -> bool:
    item.sameSubscription(subscription)

proc addSubscriptionSorted*(
    subs: var SubscriptionStore, sig: SigilName, subscription: Subscription
): bool {.gcsafe, raises: [].} =
  let exists = subs.containsValue(sig) do(item: Subscription) -> bool:
    item.sameSubscription(subscription)
  if exists:
    return false

  discard subs.addValue(sig, subscription)
  true

method addListener*(obj: Agent, tgt: WeakRef[Agent]) {.base, gcsafe, raises: [].} =
  obj.listening.incl(tgt)

method delListener*(obj: Agent, tgt: WeakRef[Agent]) {.base, gcsafe, raises: [].} =
  obj.listening.excl(tgt)

method addSubscription*(
    obj: Agent, sig: SigilName, subscription: Subscription
) {.base, gcsafe, raises: [].} =
  doAssert not obj.isNil(), "agent is nil!"
  assert subscription.hasCallable

  if addSubscriptionSorted(obj.subcriptions, sig, subscription):
    subscription.tgt[].addListener(obj.unsafeWeakRef().asAgent())

method addSubscription*(
    obj: Agent, sig: SigilName, tgt: WeakRef[Agent], slot: AgentProc
) {.base, gcsafe, raises: [].} =
  addSubscription(obj, sig, Subscription(tgt: tgt, packedSlot: slot))

method addSubscription*(
    obj: Agent,
    sig: SigilName,
    tgt: WeakRef[Agent],
    slot: AgentProc,
    directSlot: LocalAgentProc
) {.base, gcsafe, raises: [].} =
  addSubscription(obj, sig, Subscription(tgt: tgt, packedSlot: slot,
      directSlot: directSlot))

template addSubscription*(
    obj: Agent,
    sig: IndexableChars,
    tgt: Agent | WeakRef[Agent],
    slot: AgentProc
): void =
  let tgtRef = tgt.unsafeWeakRef().toKind(Agent)
  addSubscription(obj, sig.toSigilName(), tgtRef, slot)

template addSubscription*(
    obj: Agent,
    sig: IndexableChars,
    tgt: Agent | WeakRef[Agent],
    slot: AgentProc,
    directSlot: LocalAgentProc
): void =
  let tgtRef = tgt.unsafeWeakRef().toKind(Agent)
  addSubscription(obj, sig.toSigilName(), tgtRef, slot, directSlot)

var printConnectionsSlotNames* = initTable[pointer, string]()

when defined(sigilsDebugPrint):
  proc slotDebugName(subscription: Subscription): string =
    if not subscription.packedSlot.isNil:
      return printConnectionsSlotNames.getOrDefault(
        subscription.packedSlot, subscription.packedSlot.repr
      )
    if not subscription.directSlot.isNil:
      return subscription.directSlot.repr
    when not sigilsSlotEnvDisabled:
      if not subscription.envSlot.isNil:
        return subscription.envSlot.repr
    "nil"

method delSubscription*(
    self: Agent, sig: SigilName, tgt: WeakRef[Agent], slot: AgentProc
) {.base, gcsafe, raises: [].} =
  let removed = self.subcriptions.removeValuesForKey(sig) do(
      subscription: Subscription
  ) -> HybridRemoveAction:
    if subscription.tgt != tgt:
      hraKeep
    elif slot == nil or subscription.packedSlot == slot:
      hraDelete
    else:
      hraFound

  if removed.found == removed.deleted:
    tgt[].delListener(self.unsafeWeakRef().asAgent())

method delSubscription*(
    self: Agent, sig: SigilName, subscription: Subscription
) {.base, gcsafe, raises: [].} =
  let removed = self.subcriptions.removeValuesForKey(sig) do(
      item: Subscription
  ) -> HybridRemoveAction:
    if item.sameSubscription(subscription):
      hraDelete
    else:
      hraKeep

  if removed.deleted > 0 and not procCall hasSubscription(self, sig,
      subscription.tgt):
    subscription.tgt[].delListener(self.unsafeWeakRef().asAgent())


template delSubscription*(
    obj: Agent, sig: IndexableChars, tgt: WeakRef[Agent], slot: AgentProc
): void =
  delSubscription(obj, sig.toSigilName(), tgt, slot)

template delSubscription*(
    obj: Agent, sig: IndexableChars, tgt: Agent, slot: AgentProc
): void =
  let tgtRef = tgt.unsafeWeakRef().toKind(Agent)
  delSubscription(obj, sig.toSigilName(), tgtRef, slot)

proc printConnections*(agent: Agent) =
  when defined(sigilsDebugPrint):
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
      brightPrint fgGreen, "\t\t:", $item.signal, ": => ",
          $item.subscription.tgt & " slot: " & slotDebugName(item.subscription)
    brightPrint fgMagenta, "\t listening:", ""
    for listening in agent.listening:
      brightPrint fgRed, "\t\t listen: ", $listening
