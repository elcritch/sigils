import std/[hashes, options, sets, strformat, tables]
import stack_strings

import protocol
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

  AgentObj = object of RootObj
    subcriptions*: seq[tuple[signal: SigilName, subscription: Subscription]]
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
  for idx in countdown(self.subcriptions.len() - 1, 0):
    debugPrint "   removeSubscriptionsFor subs sig: ", $self.subcriptions[idx].signal
    if self.subcriptions[idx].subscription.tgt == subscriber:
      self.subcriptions.delete(idx)

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

template removeSubscriptions*(
    agent: WeakRef[Agent], subcriptions: seq[tuple[signal: SigilName,
        subscription: Subscription]]
) =
  ## remove myself from agents listening to me
  var tgts: HashSet[WeakRef[Agent]] = initHashSet[WeakRef[Agent]](
      subcriptions.len())
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

func useLinearSubscriptionScan(subsLen: int): bool {.inline.} =
  sigilsSubscriptionBinarySearchThreshold > 0 and
    subsLen < sigilsSubscriptionBinarySearchThreshold

func cmpSigilName(a, b: SigilName): int {.inline.} =
  let minLen = min(a.len, b.len)
  var idx = 0
  while idx < minLen:
    if a.data[idx] < b.data[idx]:
      return -1
    if a.data[idx] > b.data[idx]:
      return 1
    idx.inc()

  if a.len < b.len:
    -1
  elif a.len > b.len:
    1
  else:
    0

proc lowerBoundSubscription(
    subs: seq[SubscriptionEntry], sig: SigilName
): int {.inline, gcsafe, raises: [].} =
  var
    lo = 0
    hi = subs.len
  while lo < hi:
    let mid = (lo + hi) shr 1
    if cmpSigilName(subs[mid].signal, sig) < 0:
      lo = mid + 1
    else:
      hi = mid
  lo

proc upperBoundSubscription(
    subs: seq[SubscriptionEntry], sig: SigilName
): int {.inline, gcsafe, raises: [].} =
  var
    lo = 0
    hi = subs.len
  while lo < hi:
    let mid = (lo + hi) shr 1
    if cmpSigilName(subs[mid].signal, sig) <= 0:
      lo = mid + 1
    else:
      hi = mid
  lo

iterator subscriptionsForSignal(
    subs: var seq[SubscriptionEntry], sig: SigilName
): var Subscription =
  var idx = lowerBoundSubscription(subs, sig)
  while idx < subs.len and subs[idx].signal == sig:
    yield subs[idx].subscription
    idx.inc()

iterator subscriptionsForSignalLinear(
    subs: var seq[SubscriptionEntry], sig: SigilName
): var Subscription =
  for item in subs.mitems():
    if item.signal == sig or item.signal == AnySigilName:
      yield item.subscription

iterator getSubscriptions*(obj: Agent, sig: SigilName): var Subscription =
  if useLinearSubscriptionScan(obj.subcriptions.len):
    for sub in subscriptionsForSignalLinear(obj.subcriptions, sig):
      yield sub
  elif sig == AnySigilName:
    for sub in subscriptionsForSignal(obj.subcriptions, sig):
      yield sub
  elif cmpSigilName(AnySigilName, sig) <= 0:
    for sub in subscriptionsForSignal(obj.subcriptions, AnySigilName):
      yield sub
    for sub in subscriptionsForSignal(obj.subcriptions, sig):
      yield sub
  else:
    for sub in subscriptionsForSignal(obj.subcriptions, sig):
      yield sub
    for sub in subscriptionsForSignal(obj.subcriptions, AnySigilName):
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
  if useLinearSubscriptionScan(obj.subcriptions.len):
    for item in obj.subcriptions:
      if item.signal == sig:
        return true
    return false

  let idx = lowerBoundSubscription(obj.subcriptions, sig)
  idx < obj.subcriptions.len() and obj.subcriptions[idx].signal == sig

method hasSubscription*(
    obj: Agent, sig: SigilName, tgt: WeakRef[Agent]
): bool {.base, gcsafe, raises: [].} =
  if useLinearSubscriptionScan(obj.subcriptions.len):
    for item in obj.subcriptions:
      if item.signal == sig and item.subscription.tgt == tgt:
        return true
    return false

  var idx = lowerBoundSubscription(obj.subcriptions, sig)
  while idx < obj.subcriptions.len() and obj.subcriptions[idx].signal == sig:
    if obj.subcriptions[idx].subscription.tgt == tgt:
      return true
    idx.inc()

template hasSubscription*(obj: Agent, sig: SigilName, tgt: Agent): bool =
  let tgtRef = tgt.unsafeWeakRef().toKind(Agent)
  hasSubscription(obj, sig, tgtRef)

method hasSubscription*(
    obj: Agent, sig: SigilName, tgt: WeakRef[Agent], slot: AgentProc
): bool {.base, gcsafe, raises: [].} =
  if useLinearSubscriptionScan(obj.subcriptions.len):
    for item in obj.subcriptions:
      if item.signal == sig and item.subscription.tgt == tgt and
          item.subscription.packedSlot == slot:
        return true
    return false

  var idx = lowerBoundSubscription(obj.subcriptions, sig)
  while idx < obj.subcriptions.len() and obj.subcriptions[idx].signal == sig:
    if obj.subcriptions[idx].subscription.tgt == tgt and
        obj.subcriptions[idx].subscription.packedSlot == slot:
      return true
    idx.inc()

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
  if useLinearSubscriptionScan(obj.subcriptions.len):
    for item in obj.subcriptions:
      if item.signal == sig and item.subscription.sameSubscription(subscription):
        return true
    return false

  var idx = lowerBoundSubscription(obj.subcriptions, sig)
  while idx < obj.subcriptions.len() and obj.subcriptions[idx].signal == sig:
    if obj.subcriptions[idx].subscription.sameSubscription(subscription):
      return true
    idx.inc()

proc addSubscriptionSorted*(
    subs: var seq[SubscriptionEntry], sig: SigilName, subscription: Subscription
): bool {.gcsafe, raises: [].} =
  var idx = lowerBoundSubscription(subs, sig)
  while idx < subs.len and subs[idx].signal == sig:
    if subs[idx].subscription.sameSubscription(subscription):
      return false
    idx.inc()
  subs.insert((sig, subscription), idx)
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

  var
    subsFound: int
    subsDeleted: int

  if useLinearSubscriptionScan(self.subcriptions.len):
    for idx in countdown(self.subcriptions.len() - 1, 0):
      if self.subcriptions[idx].signal == sig and
          self.subcriptions[idx].subscription.tgt == tgt:
        subsFound.inc()
        if slot == nil or self.subcriptions[idx].subscription.packedSlot == slot:
          subsDeleted.inc()
          self.subcriptions.delete(idx)
  else:
    let first = lowerBoundSubscription(self.subcriptions, sig)
    var idx = upperBoundSubscription(self.subcriptions, sig)
    while idx > first:
      idx.dec()
      if self.subcriptions[idx].signal == sig and
          self.subcriptions[idx].subscription.tgt == tgt:
        subsFound.inc()
        if slot == nil or self.subcriptions[idx].subscription.packedSlot == slot:
          subsDeleted.inc()
          self.subcriptions.delete(idx)

  if subsFound == subsDeleted:
    tgt[].delListener(self.unsafeWeakRef().asAgent())

method delSubscription*(
    self: Agent, sig: SigilName, subscription: Subscription
) {.base, gcsafe, raises: [].} =
  var deleted = false
  if useLinearSubscriptionScan(self.subcriptions.len):
    for idx in countdown(self.subcriptions.len() - 1, 0):
      if self.subcriptions[idx].signal == sig and
          self.subcriptions[idx].subscription.sameSubscription(subscription):
        deleted = true
        self.subcriptions.delete(idx)
  else:
    let first = lowerBoundSubscription(self.subcriptions, sig)
    var idx = upperBoundSubscription(self.subcriptions, sig)
    while idx > first:
      idx.dec()
      if self.subcriptions[idx].signal == sig and
          self.subcriptions[idx].subscription.sameSubscription(subscription):
        deleted = true
        self.subcriptions.delete(idx)

  if deleted and not procCall hasSubscription(self, sig, subscription.tgt):
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
