import std/sets
import std/isolation
import std/options
import std/locks
import threading/smartptrs
import threading/channels

import isolateutils
import agents
import core
import threadBase

from system/ansi_c import c_raise

type
  AgentProxyShared* = ref object of AgentRemote
    remote*: WeakRef[Agent]
    proxyTwin*: WeakRef[AgentProxyShared]
    lock*: Lock
    remoteThread*: SigilThreadPtr

  AgentProxy*[T] = ref object of AgentProxyShared

proc `=destroy`*(obj: var typeof(AgentProxyShared()[])) =
  when defined(sigilsWeakRefPointer):
    let agent = WeakRef[AgentRemote](pt: cast[pointer](addr obj))
  else:
    let pt: WeakRef[pointer] = WeakRef[pointer](pt: cast[pointer](addr obj))
    let agent = cast[WeakRef[AgentRemote]](pt)
  debugPrint "PROXY Destroy: ", cast[AgentProxyShared](addr(obj)).unsafeWeakRef()
  `=destroy`(toAgentObj(cast[AgentProxyShared](addr obj)))

  debugPrint "PROXY Destroy: proxyTwin: ", obj.proxyTwin
  # need to break to proxyTwin cycle on dirst destroy
  # TODO: seems like there's a possible race condtions here as we could destroy
  # both remote and local proxies at the same time
  if not obj.proxyTwin.isNil:
    withLock obj.proxyTwin[].lock:
      obj.proxyTwin[].proxyTwin.pt = nil
      withLock obj.proxyTwin[].remoteThread[].signaledLock:
        obj.proxyTwin[].remoteThread[].signaled.excl(agent)
  try:
    let
      thr = obj.remoteThread
      proxyTwin = obj.proxyTwin.toKind(Agent)
    if not proxyTwin.isNil:
      debugPrint "send deref: ", $proxyTwin, " thr: ", getThreadId()
      thr.send(ThreadSignal(kind: Deref, deref: proxyTwin))
  except Exception:
    echo "error sending deref message for ", $obj.proxyTwin

  `=destroy`(obj.remoteThread)
  `=destroy`(obj.lock) # careful on this one -- should probably figure out a test

proc getRemote*[T](proxy: AgentProxy[T]): WeakRef[T] =
  proxy.remote.toKind(T)

proc remoteSlot*(context: Agent, params: SigilParams) {.nimcall.} =
  raise newException(AssertionDefect, "this should never be called!")

proc localSlot*(context: Agent, params: SigilParams) {.nimcall.} =
  raise newException(AssertionDefect, "this should never be called!")

method hasConnections*(proxy: AgentProxyShared): bool {.gcsafe, raises: [].} =
  withLock proxy.lock:
    result = proxy.subcriptions.len() != 0 or proxy.listening.len() != 0

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
  if slot == remoteSlot:
    var req = req.duplicate()
    #debugPrint "\t proxy:callMethod:remoteSlot: ", "req: ", $req
    debugPrint "\t proxy:callMethod:remoteSlot: ", "proxy.remote: ", $proxy.remote
    var pt: WeakRef[AgentProxyShared]
    withLock proxy.lock:
      pt = proxy.proxyTwin

    var msg = isolateRuntime ThreadSignal(
      kind: Call, slot: localSlot, req: move req, tgt: pt.toKind(Agent)
    )
    debugPrint "\t proxy:callMethod:remoteSlot: ",
      "msg: ", $msg, " proxyTwin: ", $proxy.proxyTwin
    when defined(sigilsDebug) or defined(debug):
      assert proxy.freedByThread == 0
    when defined(sigilNonBlockingThreads):
      discard
    else:
      withLock proxy.lock:
        if not proxy.proxyTwin.isNil:
          withLock proxy.remoteThread[].signaledLock:
            proxy.remoteThread[].signaled.incl(proxy.proxyTwin.toKind(AgentRemote))
          proxy.proxyTwin[].inbox.send(msg)
      proxy.remoteThread.send(ThreadSignal(kind: Trigger))
  elif slot == localSlot:
    debugPrint "\t proxy:callMethod:localSlot: "
    callSlots(proxy, req)
  else:
    var req = req.duplicate()
    debugPrint "\t callMethod:agentProxy:InitCall:Outbound: ",
      req.procName, " proxy:remote:obj: ", proxy.remote.getSigilId()
    var msg = isolateRuntime ThreadSignal(
      kind: Call, slot: slot, req: move req, tgt: proxy.remote
    )
    when defined(sigilNonBlockingThreads):
      discard
    else:
      debugPrint "\t callMethod:agentProxy:proxyTwin: ", proxy.proxyTwin
      withLock proxy.lock:
        proxy.proxyTwin[].inbox.send(msg)
        withLock proxy.remoteThread[].signaledLock:
          proxy.remoteThread[].signaled.incl(proxy.proxyTwin.toKind(AgentRemote))
      proxy.remoteThread.send(ThreadSignal(kind: Trigger))

method removeSubscriptionsFor*(
    self: AgentProxyShared, subscriber: WeakRef[Agent]
) {.gcsafe, raises: [].} =
  debugPrint "   removeSubscriptionsFor:proxy: self:id: ", $self.unsafeWeakRef()
  withLock self.lock:
    # block:
    debugPrint "   removeSubscriptionsFor:proxy:ready: self:id: ", $self.unsafeWeakRef()
    removeSubscriptionsForImpl(self, subscriber)

method unregisterSubscriber*(
    self: AgentProxyShared, listener: WeakRef[Agent]
) {.gcsafe, raises: [].} =
  debugPrint "   unregisterSubscriber:proxy: self:id: ", $self.unsafeWeakRef()
  withLock self.lock:
    # block:
    debugPrint "   unregisterSubscriber:proxy:ready: self:id: ", $self.unsafeWeakRef()
    unregisterSubscriberImpl(self, listener)

proc initProxy*[T](proxy: var AgentProxy[T],
                  agent: WeakRef[Agent],
                  thread: SigilThreadPtr,
                  isRemote = false, inbox = 1_000) =
  assert agent[] of T
  proxy = AgentProxy[T](
    remote: agent,
    remoteThread: thread,
    inbox: newChan[ThreadSignal](inbox),
  )
  proxy.lock.initLock()
  when defined(sigilsDebug):
    if remote:
      proxy.debugName = "remoteProxy::" & agent.debugName
    else:
      proxy.debugName = "localProxy::" & agent.debugName

proc bindProxies*[T](a, b: AgentProxy[T]) =
  a.proxyTwin = b.unsafeWeakRef().toKind(AgentProxyShared)
  b.proxyTwin = a.unsafeWeakRef().toKind(AgentProxyShared)

iterator findSubscribedTo(
    other: WeakRef[Agent], agent: WeakRef[Agent]
): tuple[signal: SigilName, subscription: Subscription] =
  for item in other[].subcriptions.mitems():
    if item.subscription.tgt == agent:
      yield (item.signal, Subscription(tgt: other, slot: item.subscription.slot))

proc moveToThread*[T: Agent, R: SigilThread](
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
    ct = getCurrentSigilThread()
    agent = agentTy.unsafeWeakRef.asAgent()

  var
    localProxy: AgentProxy[T]
    remoteProxy: AgentProxy[T]

  localProxy.initProxy(agent, thread.toSigilThread(), inbox = inbox)
  remoteProxy.initProxy(agent, ct, inbox = inbox)
  bindProxies(localProxy, remoteProxy)

  # handle things subscribed to `agent`, ie the inverse
  var
    oldSubscribers = agent[].subcriptions
    oldListeningSubs: seq[tuple[signal: SigilName, subscription: Subscription]]

  for listener in agent[].listening:
    for item in listener.findSubscribedTo(agent[].unsafeWeakRef()):
      oldListeningSubs.add(item)

  agent.unsubscribeFrom(agent[].listening)
  agent.removeSubscriptions(agent[].subcriptions)
  agent[].listening.clear()
  agent[].subcriptions.setLen(0)

  # update subscriptions agent is listening to use the local proxy to send events
  var listenSubs = false
  for item in oldListeningSubs:
    item.subscription.tgt[].addSubscription(item.signal, localProxy, item.subscription.slot)
    listenSubs = true
  remoteProxy.addSubscription(AnySigilName, agentTy, localSlot)

  # update my subcriptionsTable so agent uses the remote proxy to send events back
  var hasSubs = false
  for item in oldSubscribers:
    localProxy.addSubscription(item.signal, item.subscription.tgt[], item.subscription.slot)
    hasSubs = true
  agent[].addSubscription(AnySigilName, remoteProxy, remoteSlot)

  thread.send(ThreadSignal(kind: Move, item: move agentTy))
  thread.send(ThreadSignal(kind: Move, item: move remoteProxy))

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
    a: Agent,
    signal: typed,
    localProxy: AgentProxy[T],
    slot: Signal[S],
    acceptVoidSlot: static bool = false,
): void =
  ## connects `AgentProxy[T]` to remote signals
  ## 
  checkSignalTypes(a, signal, T(), slot, acceptVoidSlot)
  a.addSubscription(signalName(signal), localProxy, slot)
  assert not localProxy.proxyTwin.isNil
  assert not localProxy.remote.isNil
  withLock localProxy.proxyTwin[].lock:
    localProxy.proxyTwin[].addSubscription(AnySigilName, localProxy.remote[], localSlot)

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
  let agentSlot = `slot`(T)
  checkSignalTypes(a, signal, T(), agentSlot, acceptVoidSlot)
  a.addSubscription(signalName(signal), localProxy, agentSlot)
  assert not localProxy.proxyTwin.isNil
  assert not localProxy.remote.isNil
  withLock localProxy.proxyTwin[].lock:
    localProxy.proxyTwin[].addSubscription(AnySigilName, localProxy.remote[], localSlot)

template connectThreaded*[T, S](
    proxyTy: AgentProxy[T],
    signal: typed,
    b: Agent,
    slot: Signal[S],
    acceptVoidSlot: static bool = false,
): void =
  ## connects `AgentProxy[T]` to remote signals
  ## 
  checkSignalTypes(T(), signal, b, slot, acceptVoidSlot)
  let localProxy = Agent(proxyTy)
  localProxy.addSubscription(signalName(signal), b, slot)

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
  assert not localProxy.proxyTwin.isNil
  assert not localProxy.remote.isNil
  thr.agent.addSubscription(signalName(signal), localProxy.getRemote()[], agentSlot)

import macros

macro callCode(s: static string): untyped =
  ## calls a code to get the signal type using a static string
  result = parseStmt(s)

proc fwdSlotTy[A: Agent; B: Agent; S: static string](self: Agent, params: SigilParams) {.nimcall.} =
    let agentSlot = callCode(S)
    let req = SigilRequest(
      kind: Request, origin: SigilId(-1), procName: signalName(signal), params: params.duplicate()
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

proc fwdSlot[A: Agent; B: Agent; S: static string](self: Agent, params: SigilParams) {.nimcall.} =
    let agentSlot = callSlot(S, typeof(B))
    let req = SigilRequest(
      kind: Request, origin: SigilId(-1), procName: signalName(signal), params: params.duplicate()
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

