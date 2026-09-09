import std/sets
import std/isolation
import std/locks
import threading/smartptrs
import threading/channels

import isolateutils
import agents
import core
import threadBase

from system/ansi_c import c_raise

type
  AgentProxyShared* = ref object of AgentActor
    remote*: WeakRef[AgentActor]
    remoteThread*: SigilThreadPtr
    homeThread*: SigilThreadPtr
    forwarded*: HashSet[SigilName]
    forwardingReady*: bool

  AgentProxy*[T] = ref object of AgentProxyShared

proc `=destroy`*(obj: var typeof(AgentProxyShared()[])) =
  when defined(sigilsWeakRefPointer):
    let agent = WeakRef[AgentActor](pt: cast[pointer](addr obj))
  else:
    let pt: WeakRef[pointer] = WeakRef[pointer](pt: cast[pointer](addr obj))
    let agent = cast[WeakRef[AgentActor]](pt)
  let remoteEndpoint =
    if obj.delivery.isNil: default(AgentEndpoint)
    else: obj.delivery[].remote
  `=destroy`(toAgentObj(cast[AgentProxyShared](addr obj)))
  if not obj.homeThread.isNil:
    withLock obj.homeThread[].signaledLock:
      obj.homeThread[].signaled.excl(agent)
  if not remoteEndpoint.isNil:
    withLock remoteEndpoint[].lock:
      dec remoteEndpoint[].handles
    try:
      if not obj.remoteThread.isNil:
        obj.remoteThread.send(ThreadSignal(kind: Release,
          deref: obj.remote.toKind(Agent)))
    except Exception:
      discard
  `=destroy`(obj.inbox)
  `=destroy`(obj.forwarded)
  if obj.ready:
    deinitLock(obj.lock)

proc getRemote*[T](proxy: AgentProxy[T]): WeakRef[T] =
  proxy.remote.toKind(T)

proc remoteSlot*(context: Agent, params: SigilParams) {.nimcall.} =
  raise newException(AssertionDefect, "this should never be called!")

proc localSlot*(context: Agent, params: SigilParams) {.nimcall.} =
  raise newException(AssertionDefect, "this should never be called!")

proc hasLocalSignal*(proxy: AgentProxyShared, sig: SigilName): bool {.gcsafe,
    raises: [].} =
  for item in proxy.subcriptions:
    if item.signal == sig:
      return true

template removeForwarded(proxy: AgentProxyShared, sigs: untyped) =
  var removed: seq[SigilName]
  withLock proxy.lock:
    for sig in sigs:
      if sig in proxy.forwarded and not proxy.hasLocalSignal(sig):
        proxy.forwarded.excl(sig)
        removed.add(sig)
  let proxyRef = proxy.unsafeWeakRef().asAgent()
  let remoteEndpoint = proxy.delivery[].remote
  withLock remoteEndpoint[].lock:
    if proxy.forwardingReady and remoteEndpoint.isAlive:
      for sig in removed:
        proxy.remote[].delSubscription(sig, proxyRef, localSlot)

proc ensureForwarded(proxy: AgentProxyShared, sig: SigilName) {.gcsafe,
    raises: [].} =
  if not proxy.forwardingReady:
    return
  withLock proxy.lock:
    if sig in proxy.forwarded:
      return
    proxy.forwarded.incl(sig)
  let remoteEndpoint = proxy.delivery[].remote
  withLock remoteEndpoint[].lock:
    if remoteEndpoint.isAlive:
      proxy.remote[].addSubscription(sig, proxy, localSlot)

method hasConnections*(proxy: AgentProxyShared): bool {.gcsafe, raises: [].} =
  withLock proxy.lock:
    result = proxy.subcriptions.len() != 0 or proxy.listening.len() != 0

method addSubscription*(
    obj: AgentProxyShared, sig: SigilName, subscription: Subscription
) {.gcsafe, raises: [].} =
  procCall addSubscription(AgentActor(obj), sig, subscription)
  obj.ensureForwarded(sig)

method addSubscription*(
    obj: AgentProxyShared, sig: SigilName, tgt: WeakRef[Agent], slot: AgentProc
) {.gcsafe, raises: [].} =
  obj.addSubscription(sig, Subscription(tgt: tgt, packedSlot: slot))

method delSubscription*(
    self: AgentProxyShared, sig: SigilName, subscription: Subscription
) {.gcsafe, raises: [].} =
  procCall delSubscription(AgentActor(self), sig, subscription)
  self.removeForwarded([sig])

method delSubscription*(
    self: AgentProxyShared, sig: SigilName, tgt: WeakRef[Agent], slot: AgentProc
) {.gcsafe, raises: [].} =
  procCall delSubscription(AgentActor(self), sig, tgt, slot)
  self.removeForwarded([sig])

proc dispatchProxy(endpoint: AgentEndpoint, req: sink SigilRequest,
    slot: AgentProc): SigilResponse {.gcsafe.} =
  if not endpoint.isAlive:
    return
  let home = cast[SigilThreadPtr](endpoint[].scheduler)
  if getCurrentSigilThread() == home and
      (endpoint[].owner.isNil or (not executingActor.isNil and
       executingActor[].target == endpoint[].owner[].target)):
    {.cast(gcsafe).}:
      return endpoint[].target[].callMethod(ensureMove(req), slot)
  home.send(ThreadSignal(kind: Call, tgt: endpoint[].target,
    endpoint: endpoint, req: ensureMove(req), slot: slot))

method callMethod*(
    proxy: AgentProxyShared, req: sink SigilRequest, slot: AgentProc
): SigilResponse {.gcsafe, effectsOf: slot.} =
  let endpoint = proxy.delivery
  let ct = getCurrentSigilThread()
  if ct != proxy.homeThread or
      (not endpoint[].owner.isNil and (executingActor.isNil or
       executingActor[].target != endpoint[].owner[].target)):
    return dispatchProxy(endpoint, ensureMove(req), slot)
  if slot == localSlot or slot == remoteSlot:
    proxy.callSlots(ensureMove(req))
  else:
    let remote = endpoint[].remote
    if remote.isAlive:
      proxy.remoteThread.send(ThreadSignal(kind: Call, slot: slot,
        req: ensureMove(req), tgt: remote[].target, endpoint: remote))

method removeSubscriptionsFor*(
    self: AgentProxyShared, subscriber: WeakRef[Agent]
) {.gcsafe, raises: [].} =
  debugPrint "   removeSubscriptionsFor:proxy: self:id: ", $self.unsafeWeakRef()
  debugPrint "   removeSubscriptionsFor:proxy:ready: self:id: ",
      $self.unsafeWeakRef()
  var sigs: HashSet[SigilName] = initHashSet[SigilName]()
  withLock self.lock:
    for item in self.subcriptions:
      sigs.incl(item.signal)
    procCall removeSubscriptionsFor(Agent(self), subscriber)
  self.removeForwarded(sigs)

method unregisterSubscriber*(
    self: AgentProxyShared, listener: WeakRef[Agent]
) {.gcsafe, raises: [].} =
  debugPrint "   unregisterSubscriber:proxy: self:id: ", $self.unsafeWeakRef()
  debugPrint "   unregisterSubscriber:proxy:ready: self:id: ",
      $self.unsafeWeakRef()
  procCall unregisterSubscriber(AgentActor(self), listener)

proc initProxy*[T](proxy: var AgentProxy[T],
                  agent: WeakRef[AgentActor],
                  thread: SigilThreadPtr,
                  forwardingReady = true,
                  inbox = 1_000) =
  assert agent[] of T
  agent[].ensureActorReady(inbox)
  proxy = AgentProxy[T](
    remote: agent,
    remoteThread: thread,
    homeThread: getCurrentSigilThread(),
    forwarded: initHashSet[SigilName](),
    forwardingReady: forwardingReady,
    inbox: newSigilChan(inbox),
  )
  proxy.lock.initLock()
  proxy.ready = true
  let endpoint = proxy.endpoint()
  let remoteEndpoint = agent[].endpoint()
  withLock remoteEndpoint[].lock:
    if not remoteEndpoint.isAlive:
      raise newException(ValueError, "remote actor is closed")
    inc remoteEndpoint[].handles
  endpoint[].scheduler = cast[pointer](proxy.homeThread)
  endpoint[].remote = remoteEndpoint
  endpoint[].owner = executingActor
  endpoint[].dispatch = dispatchProxy
  when defined(sigilsDebug):
    proxy.debugName = "proxy::" & agent.debugName

iterator findSubscribedTo(
    other: WeakRef[Agent], agent: WeakRef[Agent]
): tuple[signal: SigilName, subscription: Subscription] =
  for item in other[].subcriptions:
    if item.subscription.tgt == agent:
      yield (item.signal, Subscription(tgt: other,
          packedSlot: item.subscription.packedSlot,
          cloneMode: item.subscription.cloneMode))

proc moveToThread*[T: AgentActor, R: SigilThread](
    agentTy: var T, thread: ptr R, inbox = 1_000
): AgentProxy[T] {.gcsafe.} =
  ## move agent to another thread
  debugPrint "moveToThread: ", $agentTy.unsafeWeakRef()
  if not isUniqueRef(agentTy):
    raise newException(
      AccessViolationDefect,
      "agent must be unique and not shared to be passed to another thread! " &
        "GC ref is: " & $agentTy.unsafeGcCount(),
    )
  var
    agent = agentTy.unsafeWeakRef.toKind(AgentActor)
  let agentRef = agent.toKind(Agent)

  var
    localProxy: AgentProxy[T]

  localProxy.initProxy(agent, thread.toSigilThread(), inbox = inbox)

  # handle things subscribed to `agent`, ie the inverse
  var
    oldSubscribers = agent[].subcriptions
    oldListeningSubs: seq[tuple[signal: SigilName, subscription: Subscription]]

  for listener in agent[].listening:
    for item in listener.findSubscribedTo(agentRef):
      oldListeningSubs.add(item)

  agentRef.unsubscribeFrom(agent[].listening)
  agentRef.removeSubscriptions(agent[].subcriptions)
  agent[].listening.clear()
  agent[].subcriptions.setLen(0)

  # update subscriptions agent is listening to use the local proxy to send events
  var listenSubs = false
  for item in oldListeningSubs:
    item.subscription.tgt[].addSubscription(
      item.signal,
      Subscription(
        tgt: localProxy.unsafeWeakRef().asAgent(),
        packedSlot: item.subscription.packedSlot,
        cloneMode: item.subscription.cloneMode,
      ),
    )
    listenSubs = true

  # update my subcriptionsTable so agent uses the remote proxy to send events back
  var hasSubs = false
  for item in oldSubscribers:
    localProxy.addSubscription(
      item.signal,
      Subscription(
        tgt: item.subscription.tgt,
        packedSlot: item.subscription.packedSlot,
        cloneMode: item.subscription.cloneMode,
      ),
    )
    hasSubs = true

  thread.toSigilThread().attachActor(agentTy)
  when defined(gcOrc):
    GC_runOrc()
  thread.send(ThreadSignal(kind: Move, item: move agentTy))

  return localProxy

template connectThreaded*[T, U, S](
    proxyTy: AgentProxy[T],
    signal: typed,
    b: AgentProxy[U],
    slot: Signal[S],
    acceptVoidSlot: static bool = false,
): void =
  ## connects `AgentProxy[T]` to remote signals
  ##
  checkSignalTypes(T(), signal, U(), slot, acceptVoidSlot)
  let localProxy = Agent(proxyTy)
  localProxy.addSubscription(signalName(signal), b, slot)

template connectThreaded*[T, S](
    remoteRouter: AgentProxy[T],
    signal: typed,
    b: Agent,
    slot: Signal[S],
    acceptVoidSlot: static bool = false,
): void =
  ## connects `AgentProxy[T]` to remote signals
  ##
  checkSignalTypes(T(), signal, b, slot, acceptVoidSlot)
  let localProxy = Agent(remoteRouter)
  localProxy.addSubscription(signalName(signal), b, slot)

template connectThreaded*[T, S](
    a: Agent,
    signal: typed,
    localProxy: AgentProxy[T],
    slot: Signal[S],
    acceptVoidSlot: static bool = false,
): void =
  ## connects `AgentProxy[T]` to remote signals
  ##
  checkSignalTypes(a, signal, T(), slot, acceptVoidSlot)
  assert not localProxy.remote.isNil
  a.addSubscription(signalName(signal), localProxy, slot)

template connectThreaded*[T](
    a: Agent,
    signal: typed,
    localProxy: AgentProxy[T],
    slot: typed,
    acceptVoidSlot: static bool = false,
): void =
  ## connects `AgentProxy[T]` to remote signals
  ##
  checkSignalThreadSafety(SignalTypes.`signal`(typeof(a)))
  assert not localProxy.remote.isNil
  let agentSlot = `slot`(T)
  checkSignalTypes(a, signal, T(), agentSlot, acceptVoidSlot)
  a.addSubscription(signalName(signal), localProxy, agentSlot)

template connectThreaded*[T](
    thr: SigilThreadPtr,
    signal: typed,
    localProxy: AgentProxy[T],
    slot: typed,
    acceptVoidSlot: static bool = false,
): void =
  ## connects `AgentProxy[T]` to remote signals
  ##
  checkSignalThreadSafety(SignalTypes.`signal`(typeof(thr.agent)))
  let agentSlot = `slot`(T)
  checkSignalTypes(thr.agent, signal, T(), agentSlot, acceptVoidSlot)
  assert not localProxy.remote.isNil
  thr.agent.addSubscription(signalName(signal), localProxy.getRemote()[], agentSlot)

import macros

macro callCode(s: static string): untyped =
  ## calls a code to get the signal type using a static string
  result = parseStmt(s)

proc fwdSlotTy[A: Agent; B: Agent; S: static string](self: Agent,
    params: SigilParams) {.nimcall.} =
  let agentSlot = callCode(S)
  let req = SigilRequest(
    kind: Request, origin: SigilId(-1), procName: signalName(signal),
        params: params.clone(CloneMode.Rc)
  )
  var msg = ThreadSignal(kind: Call)
  msg.slot = agentSlot
  msg.req = req
  msg.tgt = self.unsafeWeakRef().asAgent()
  let ct = getCurrentSigilThread()
  ct.send(msg)

template connectQueued*[T](
    a: Agent,
    signal: typed,
    b: Agent,
    slot: Signal[T],
    acceptVoidSlot: static bool = false,
): void =
  ## Queued connection helper: route a signal to a target slot by
  ## enqueueing a `Call` on a specific `SigilThread`'s inputs channel.
  checkSignalTypes(a, signal, b, slot, acceptVoidSlot)
  let ct = getCurrentSigilThread()
  let fs: AgentProc = fwdSlotTy[a, b, astToStr(slot)]
  a.addSubscription(
    signalName(signal),
    Subscription(
      tgt: b.unsafeWeakRef().asAgent(),
      packedSlot: fs,
      cloneMode: CloneMode.Rc,
    ),
  )

macro callSlot(s: static string, a: typed): untyped =
  ## calls a slot to get the signal type using a static string
  let id = ident(s)
  result = quote do:
    `id`(`a`)
  echo "callSlot:result: ", result.repr

proc fwdSlot[A: Agent; B: Agent; S: static string](self: Agent,
    params: SigilParams) {.nimcall.} =
  let agentSlot = callSlot(S, typeof(B))
  let req = SigilRequest(
    kind: Request,
    origin: SigilId(-1),
    procName: signalName(signal),
    params: params.clone(CloneMode.Rc)
  )
  var msg = ThreadSignal(kind: Call)
  msg.slot = agentSlot
  msg.req = req
  msg.tgt = self.unsafeWeakRef().asAgent()
  let ct = getCurrentSigilThread()
  ct.send(msg)

template connectQueued*(
    a: Agent,
    signal: typed,
    b: Agent,
    slot: untyped,
    acceptVoidSlot: static bool = false,
): void =
  ## Queued connection helper: route a signal to a target slot by
  ## enqueueing a `Call` on a specific `SigilThread`'s inputs channel.
  let agentSlot = `slot`(typeof(b))
  checkSignalTypes(a, signal, b, agentSlot, acceptVoidSlot)
  let ct = getCurrentSigilThread()
  let fs: AgentProc = fwdSlot[a, b, astToStr(slot)]
  a.addSubscription(
    signalName(signal),
    Subscription(
      tgt: b.unsafeWeakRef().asAgent(),
      packedSlot: fs,
      cloneMode: CloneMode.Rc,
    ),
  )
