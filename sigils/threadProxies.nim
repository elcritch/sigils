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
  debugPrint "PROXY Destroy: ", cast[AgentProxyShared](addr(obj)).unsafeWeakRef()
  `=destroy`(toAgentObj(cast[AgentProxyShared](addr obj)))

  if not obj.homeThread.isNil:
    withLock obj.homeThread[].signaledLock:
      obj.homeThread[].signaled.excl(agent)

  try:
    if not obj.remoteThread.isNil:
      obj.remoteThread.send(ThreadSignal(kind: Deref,
          deref: agent.toKind(Agent)))
  except Exception:
    echo "error sending deref message for proxy"

  `=destroy`(obj.remoteThread)
  `=destroy`(obj.homeThread)
  `=destroy`(obj.forwarded)
  `=destroy`(obj.lock) # careful on this one -- should probably figure out a test

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

proc hasAnySigil(proxy: AgentProxyShared): bool {.gcsafe, raises: [].} =
  proxy.hasLocalSignal(AnySigilName)

proc syncForwarded(proxy: AgentProxyShared) {.gcsafe, raises: [].}

proc removeForwarded(proxy: AgentProxyShared, sig: SigilName) {.gcsafe,
    raises: [].} =
  withLock proxy.lock:
    if sig notin proxy.forwarded:
      return
    if proxy.hasLocalSignal(sig):
      return
    proxy.forwarded.excl(sig)
  if proxy.forwardingReady and not proxy.remote.isNil:
    proxy.remote[].delSubscription(sig, proxy.unsafeWeakRef().asAgent(), localSlot)
  if sig == AnySigilName:
    proxy.syncForwarded()

proc ensureForwarded(proxy: AgentProxyShared, sig: SigilName) {.gcsafe,
    raises: [].} =
  if not proxy.forwardingReady:
    return
  if sig != AnySigilName and proxy.hasAnySigil():
    proxy.ensureForwarded(AnySigilName)
    return
  if sig == AnySigilName:
    var others: seq[SigilName]
    withLock proxy.lock:
      for name in proxy.forwarded:
        if name != AnySigilName:
          others.add(name)
    for name in others:
      proxy.removeForwarded(name)
  withLock proxy.lock:
    if sig in proxy.forwarded:
      return
    proxy.forwarded.incl(sig)
  if not proxy.remote.isNil:
    proxy.remote[].addSubscription(sig, proxy, localSlot)

proc syncForwarded(proxy: AgentProxyShared) {.gcsafe, raises: [].} =
  var signals: HashSet[SigilName] = initHashSet[SigilName]()
  withLock proxy.lock:
    for item in proxy.subcriptions:
      signals.incl(item.signal)
  for sig in signals:
    proxy.ensureForwarded(sig)

method hasConnections*(proxy: AgentProxyShared): bool {.gcsafe, raises: [].} =
  withLock proxy.lock:
    result = proxy.subcriptions.len() != 0 or proxy.listening.len() != 0

method addSubscription*(
    obj: AgentProxyShared, sig: SigilName, tgt: WeakRef[Agent], slot: AgentProc
) {.gcsafe, raises: [].} =
  procCall addSubscription(AgentActor(obj), sig, tgt, slot)
  obj.ensureForwarded(sig)

method delSubscription*(
    self: AgentProxyShared, sig: SigilName, tgt: WeakRef[Agent], slot: AgentProc
) {.gcsafe, raises: [].} =
  procCall delSubscription(AgentActor(self), sig, tgt, slot)
  self.removeForwarded(sig)

method callMethod*(
    proxy: AgentProxyShared, req: SigilRequest, slot: AgentProc
): SigilResponse {.gcsafe, effectsOf: slot.} =
  ## Route's an rpc request.
  debugPrint "callMethod: proxy: ",
    $proxy.unsafeWeakRef().asAgent(),
    " refcount: ",
    proxy.unsafeGcCount(),
    " slot: ",
    repr(slot)
  let ct = getCurrentSigilThread()
  if not proxy.homeThread.isNil and ct != proxy.homeThread:
    var req = req.duplicate()
    var msg = isolateRuntime ThreadSignal(
      kind: Call, slot: slot, req: move req,
      tgt: proxy.unsafeWeakRef().asAgent()
    )
    when defined(sigilsDebug) or defined(debug):
      assert proxy.freedByThread == 0
    when defined(sigilNonBlockingThreads):
      discard
    else:
      proxy.inbox.send(msg)
      proxy.homeThread.signal(proxy.unsafeWeakRef().toKind(AgentActor))
      proxy.homeThread.send(ThreadSignal(kind: Trigger))
    return

  if slot == localSlot or slot == remoteSlot:
    debugPrint "\t proxy:callMethod:localSlot: "
    proxy.callSlots(req)
  else:
    var req = req.duplicate()
    debugPrint "\t callMethod:agentProxy:InitCall:Outbound: ",
      req.procName, " proxy:remote:obj: ", proxy.remote.getSigilId()
    var msg = isolateRuntime ThreadSignal(
      kind: Call, slot: slot, req: move req, tgt: proxy.remote.toKind(Agent)
    )
    when defined(sigilNonBlockingThreads):
      discard
    else:
      proxy.remote[].inbox.send(msg)
      proxy.remoteThread.signal(proxy.remote)
      proxy.remoteThread.send(ThreadSignal(kind: Trigger))

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
  for sig in sigs:
    self.removeForwarded(sig)

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
    inbox: newChan[ThreadSignal](inbox),
  )
  proxy.lock.initLock()
  proxy.ready = true
  when defined(sigilsDebug):
    proxy.debugName = "proxy::" & agent.debugName

iterator findSubscribedTo(
    other: WeakRef[Agent], agent: WeakRef[Agent]
): tuple[signal: SigilName, subscription: Subscription] =
  for item in other[].subcriptions.mitems():
    if item.subscription.tgt == agent:
      yield (item.signal, Subscription(tgt: other,
          slot: item.subscription.slot))

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
    item.subscription.tgt[].addSubscription(item.signal, localProxy,
        item.subscription.slot)
    listenSubs = true

  # update my subcriptionsTable so agent uses the remote proxy to send events back
  var hasSubs = false
  for item in oldSubscribers:
    localProxy.addSubscription(item.signal, item.subscription.tgt,
        item.subscription.slot)
    hasSubs = true

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
        params: params.duplicate()
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
  a.addSubscription(signalName(signal), b, fs)

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
    params: params.duplicate()
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
  a.addSubscription(signalName(signal), b, fs)
