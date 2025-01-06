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
    remoteThread*: ptr SigilThread

  AgentProxy*[T] = ref object of AgentProxyShared

proc `=destroy`*(obj: var typeof(AgentProxyShared()[])) =
  debugPrint "PROXY Destroy: ", cast[AgentProxyShared](addr(obj)).unsafeWeakRef()
  `=destroy`(toAgentObj(cast[AgentProxyShared](addr obj)))

  debugPrint "PROXY Destroy: proxyTwin: ", obj.proxyTwin
  # need to break to proxyTwin cycle on dirst destroy
  # TODO: seems like there's race condtions here as we could destroy
  # both remote and local proxies at the same time
  if not obj.proxyTwin.isNil:
    withLock obj.proxyTwin[].lock:
      obj.proxyTwin[].proxyTwin.pt = nil
  try:
    let
      thr = obj.remoteThread
      proxyTwin = obj.proxyTwin.toKind(Agent)
    if not proxyTwin.isNil:
      debugPrint "send deref: ", $proxyTwin, " thr: ", thr[].id
      thr[].send(ThreadSignal(kind: Deref, deref: proxyTwin))
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

method callMethod*(
    proxy: AgentProxyShared, req: SigilRequest, slot: AgentProc
): SigilResponse {.gcsafe, effectsOf: slot.} =
  ## Route's an rpc request. 
  debugPrint "callMethod: proxy: ", $proxy.unsafeWeakRef().asAgent(), " refcount: ", proxy.unsafeGcCount(), " slot: ", repr(slot)
  if slot == remoteSlot:
    var req = req.deepCopy()
    debugPrint "\t proxy:callMethod:remoteSlot: ", "req: ", $req
    debugPrint "\t proxy:callMethod:remoteSlot: ", "proxy.remote: ", $proxy.remote
    var pt: WeakRef[AgentProxyShared]
    withLock proxy.lock:
      pt = proxy.proxyTwin

    var msg = isolateRuntime ThreadSignal(
      kind: Call,
      slot: localSlot,
      req: move req,
      tgt: pt.toKind(Agent)
    )
    debugPrint "\t proxy:callMethod:remoteSlot: ", "msg: ", $msg, " proxyTwin: ", $proxy.proxyTwin
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
      proxy.remoteThread[].send(ThreadSignal(kind: Trigger))
  elif slot == localSlot:
    debugPrint "\t proxy:callMethod:localSlot: "
    callSlots(proxy, req)
  else:
    var req = req.deepCopy()
    debugPrint "\t callMethod:agentProxy:InitCall:Outbound: ", req.procName, " proxy:remote:obj: ", proxy.remote.getId()
    var msg = isolateRuntime ThreadSignal(kind: Call, slot: slot, req: move req, tgt: proxy.remote)
    when defined(sigilNonBlockingThreads):
      discard
    else:
      debugPrint "\t callMethod:agentProxy:proxyTwin: ", proxy.proxyTwin
      withLock proxy.lock:
        proxy.proxyTwin[].inbox.send(msg)
        withLock proxy.remoteThread[].signaledLock:
          proxy.remoteThread[].signaled.incl(proxy.proxyTwin.toKind(AgentRemote))
      proxy.remoteThread[].send(ThreadSignal(kind: Trigger))

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

proc findSubscribedToSignals(
    listening: HashSet[WeakRef[Agent]], agent: WeakRef[Agent]
): Table[SigilName, OrderedSet[Subscription]] =
  ## remove myself from agents I'm subscribed to
  for obj in listening:
    debugPrint "finding subscribed: ", $obj
    var toAdd = initOrderedSet[Subscription]()
    for signal, subscriberPairs in obj[].subcriptionsTable.mpairs():
      for item in subscriberPairs:
        if item.tgt == agent:
          toAdd.incl(Subscription(tgt: obj, slot: item.slot))
          # echo "agentRemoved: ", "tgt: ", xid.toPtr.repr, " id: ", agent.debugId, " obj: ", obj[].debugId, " name: ", signal
      result[signal] = move toAdd

proc moveToThread*[T: Agent, R: SigilThread](
    agentTy: var T,
    thread: ptr R
): AgentProxy[T] =
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

    localProxy = AgentProxy[T](
        remote: agent,
        remoteThread: thread.toSigilThread(),
        inbox: newChan[ThreadSignal](1_000),
    )
    remoteProxy = AgentProxy[T](
        remote: agent,
        remoteThread: ct,
        inbox: newChan[ThreadSignal](1_000),
    )
  localProxy.lock.initLock()
  remoteProxy.lock.initLock()
  localProxy.proxyTwin = remoteProxy.unsafeWeakRef().toKind(AgentProxyShared)
  remoteProxy.proxyTwin = localProxy.unsafeWeakRef().toKind(AgentProxyShared)
  when defined(sigilsDebug):
    localProxy.debugName = "localProxy::" & agentTy.debugName 
    remoteProxy.debugName = "remoteProxy::" & agentTy.debugName 

  # handle things subscribed to `agent`, ie the inverse
  var
    oldSubscribers = agent[].subcriptionsTable
    oldListeningSubs = agent[].listening.findSubscribedToSignals(agent[].unsafeWeakRef)

  agent.unsubscribeFrom(agent[].listening)
  agent.removeSubscriptions(agent[].subcriptionsTable)
  agent[].listening.clear()
  agent[].subcriptionsTable.clear()

  # update subscriptions agent is listening to use the local proxy to send events
  var listenSubs = false
  for signal, subscriptions in oldListeningSubs.mpairs():
    for subscription in subscriptions:
      subscription.tgt[].addSubscription(signal, localProxy, subscription.slot)
      listenSubs = true
  remoteProxy.addSubscription(AnySigilName, agentTy, localSlot)

  # update my subcriptionsTable so agent uses the remote proxy to send events back
  var hasSubs = false
  for signal, subscriberPairs in oldSubscribers.mpairs():
    for sub in subscriberPairs:
      # echo "signal: ", signal, " subscriber: ", tgt.getId
      localProxy.addSubscription(signal, sub.tgt[], sub.slot)
      hasSubs = true
  agent[].addSubscription(AnySigilName, remoteProxy, remoteSlot)

  thread[].send(ThreadSignal(kind: Move, item: move agentTy))
  thread[].send(ThreadSignal(kind: Move, item: move remoteProxy))

  return localProxy


template connect*[T, S](
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
  # ugh, this should be locked based on remote proxy still existing?
  assert not localProxy.proxyTwin.isNil
  assert not localProxy.remote.isNil
  localProxy.proxyTwin[].addSubscription(AnySigilName, localProxy.remote[], localSlot)

template connect*[T](
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
  # ugh, this should be locked based on remote proxy still existing?
  assert not localProxy.proxyTwin.isNil
  assert not localProxy.remote.isNil
  localProxy.proxyTwin[].addSubscription(AnySigilName, localProxy.remote[], localSlot)

template connect*[T, S](
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
