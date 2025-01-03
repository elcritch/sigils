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
    remoteThread*: SigilThread

  AgentProxy*[T] = ref object of AgentProxyShared

proc `=destroy`*(obj: var typeof(AgentProxyShared()[])) =
  debugPrint "PROXY Destroy: ", cast[AgentProxyShared](addr(obj)).unsafeWeakRef()
  # withLock obj.lock:
  block:
    `=destroy`(toAgentObj(cast[AgentProxyShared](addr obj)))

    `=destroy`(obj.remote)
    `=destroy`(obj.remoteThread)

    try:
      let
        thr = obj.remoteThread
        remoteProxy = obj.proxyTwin.toKind(Agent)
      debugPrint "send deref: ", thr[].id
      thr[].inputs.send(unsafeIsolate ThreadSignal(kind: Deref, deref: remoteProxy))
    except Exception:
      echo "error sending deref message for ", $obj.proxyTwin

    # careful on this one -- should probably figure out a test
    # in case the compiler ever changes
    `=destroy`(obj.lock)

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
    var msg = isolateRuntime ThreadSignal(kind: Call, slot: localSlot, req: move req, tgt: proxy.Agent.unsafeWeakRef)
    debugPrint "\t proxy:callMethod:remoteSlot: ", "msg: ", $msg, " proxyTwin: ", $proxy.proxyTwin
    when defined(sigilsDebug) or defined(debug):
      assert proxy.freedByThread == 0
    when defined(sigilNonBlockingThreads):
      discard
    else:
      proxy.proxyTwin[].inbox.send(msg)
      withLock proxy.remoteThread[].signaledLock:
        proxy.remoteThread[].signaled.incl(proxy.proxyTwin.toKind(AgentRemote))
      proxy.remoteThread[].inputs.send(unsafeIsolate ThreadSignal(kind: Trigger))
  elif slot == localSlot:
    debugPrint "callMethod: proxy: ", "localSlot"
    discard
  #   debugPrint "\t callMethod:agentProxy:localSlot: req: ", $req
  #   callSlots(proxy, req)
  else:
    var req = req.deepCopy()
    # echo "proxy:callMethod: ", " proxy:refcount: ", proxy.unsafeGcCount()
    # echo "proxy:callMethod: ", " proxy.obj.remote:refcount: ", proxy.obj.remote[].unsafeGcCount()
    debugPrint "\t callMethod:agentProxy:InitCall:Outbound: ", req.procName, " proxy:remote:obj: ", proxy.remote.getId()
    # GC_ref(proxy)
    var msg = isolateRuntime ThreadSignal(kind: Call, slot: slot, req: move req, tgt: proxy.remote)
    when defined(sigilNonBlockingThreads):
      discard
    else:
      debugPrint "\t callMethod:agentProxy:proxyTwin: ", proxy.proxyTwin
      proxy.proxyTwin[].inbox.send(msg)
      withLock proxy.remoteThread[].signaledLock:
        proxy.remoteThread[].signaled.incl(proxy.proxyTwin.toKind(AgentRemote))
      proxy.remoteThread[].inputs.send(unsafeIsolate ThreadSignal(kind: Trigger))

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
    listening: HashSet[WeakRef[Agent]], xid: WeakRef[Agent]
): Table[SigilName, OrderedSet[Subscription]] =
  ## remove myself from agents I'm subscribed to
  for obj in listening:
    debugPrint "freeing subscribed: ", $obj[].getId()
    var toAdd = initOrderedSet[Subscription]()
    for signal, subscriberPairs in obj[].subcriptionsTable.mpairs():
      for item in subscriberPairs:
        if item.tgt == xid:
          toAdd.incl(Subscription(tgt: obj, slot: item.slot))
          # echo "agentRemoved: ", "tgt: ", xid.toPtr.repr, " id: ", agent.debugId, " obj: ", obj[].debugId, " name: ", signal
      result[signal] = move toAdd

proc moveToThread*[T: Agent, R: SigilThreadBase](
    agentTy: var T,
    thread: SharedPtr[R]
): AgentProxy[T] =
  ## move agent to another thread
  debugPrint "moveToThread: ", $agentTy.getId()
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
        remoteThread: thread,
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
  if listenSubs:
    remoteProxy.addSubscription(AnySigilName, agentTy, remoteSlot)

  # update my subcriptionsTable so agent uses the remote proxy to send events back
  var hasSubs = false
  for signal, subscriberPairs in oldSubscribers.mpairs():
    for sub in subscriberPairs:
      # echo "signal: ", signal, " subscriber: ", tgt.getId
      localProxy.addSubscription(signal, sub.tgt[], sub.slot)
      hasSubs = true
  if hasSubs:
    agent[].addSubscription(AnySigilName, remoteProxy, remoteSlot)
    remoteProxy.addSubscription(AnySigilName, localProxy, localSlot)

  thread[].inputs.send(unsafeIsolate ThreadSignal(kind: Move, item: move agentTy))
  thread[].inputs.send(unsafeIsolate ThreadSignal(kind: Move, item: move remoteProxy))

  return localProxy


# template connect*[T, S](
#     a: Agent,
#     signal: typed,
#     b: AgentProxy[T],
#     slot: Signal[S],
#     acceptVoidSlot: static bool = false,
# ): void =
#   ## connects `AgentProxy[T]` to remote signals
#   ## 
#   checkSignalTypes(a, signal, T(), slot, acceptVoidSlot)
#   a.addSubscription(signalName(signal), b, slot)

# template connect*[T](
#     a: Agent,
#     signal: typed,
#     b: AgentProxy[T],
#     slot: typed,
#     acceptVoidSlot: static bool = false,
# ): void =
#   ## connects `AgentProxy[T]` to remote signals
#   ## 
#   checkSignalThreadSafety(SignalTypes.`signal`(typeof(a)))
#   let agentSlot = `slot`(T)
#   checkSignalTypes(a, signal, T(), agentSlot, acceptVoidSlot)
#   a.addSubscription(signalName(signal), b, agentSlot)

# template connect*[T, S](
#     proxyTy: AgentProxy[T],
#     signal: typed,
#     b: Agent,
#     slot: Signal[S],
#     acceptVoidSlot: static bool = false,
# ): void =
#   ## connects `AgentProxy[T]` to remote signals
#   ## 
#   checkSignalTypes(T(), signal, b, slot, acceptVoidSlot)
#   let ct = getCurrentSigilThread()
#   let proxy = Agent(proxyTy)
#   # let bref = unsafeWeakRef[Agent](b)
#   # proxy.extract()[].addSubscription(signalName(signal), proxy, slot)
#   proxy.addSubscription(signalName(signal), b, slot)

#   # thread[].inputs.send( unsafeIsolate ThreadSignal(kind: Register, shared: ensureMove agent))

#   # TODO: This is wrong! but I wanted to get something running...
#   # ct[].proxies.incl(proxy)
