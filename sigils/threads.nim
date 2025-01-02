import std/sets
import std/isolation
import std/options
import std/locks
import threading/smartptrs
import threading/channels

import isolateutils
import agents
import core

from system/ansi_c import c_raise

export smartptrs, isolation
export isolateutils

type
  SigilChanRef* = ref object of RootObj
    ch*: Chan[ThreadSignal]

  SigilChan* = SharedPtr[SigilChanRef]

  AgentProxyShared* = ref object of Agent
    remote*: WeakRef[Agent]
    proxyTwin*: WeakRef[AgentProxyShared]
    lock*: Lock
    remoteThread*: SigilThread
    inbox*: Chan[ThreadSignal]

  AgentProxy*[T] = ref object of AgentProxyShared

  ThreadSignalKind* {.pure.} = enum
    Call
    Move
    Trigger
    Deref

  ThreadSignal* = object
    case kind*: ThreadSignalKind
    of Call:
      slot*: AgentProc
      req*: SigilRequest
      tgt*: WeakRef[Agent]
    of Move:
      item*: Agent
    of Trigger:
      discard
    of Deref:
      deref*: WeakRef[Agent]

  SigilThreadBase* = object of RootObj
    id*: int
    inputs*: SigilChan

    signaledLock*: Lock
    signaled*: HashSet[WeakRef[AgentProxyShared]]
    references*: HashSet[Agent]

  SigilThreadObj* = object of SigilThreadBase
    thr*: Thread[SharedPtr[SigilThreadObj]]

  SigilThread* = SharedPtr[SigilThreadObj]

var localSigilThread {.threadVar.}: Option[SigilThread]

proc `=destroy`*(obj: var typeof(AgentProxyShared()[])) =
  debugPrint "PROXY Destroy: ", cast[AgentProxyShared](addr(obj)).unsafeWeakRef()
  # withLock obj.lock:
  block:
    `=destroy`(toAgentObj(cast[AgentProxyShared](addr obj)))

    `=destroy`(obj.remote)
    `=destroy`(obj.remoteThread)

    # careful on this one -- should probably figure out a test
    # in case the compiler ever changes
    `=destroy`(obj.lock)

proc newSigilChan*(): SigilChan =
  let cref = SigilChanRef.new()
  GC_ref(cref)
  result = newSharedPtr(unsafeIsolate cref)
  result[].ch = newChan[ThreadSignal](1_000)

method trySend*(chan: SigilChanRef, msg: sink Isolated[ThreadSignal]): bool {.gcsafe, base.} =
  # debugPrint &"chan:trySend:"
  result = chan[].ch.trySend(msg)
  # debugPrint &"chan:trySend: res: {$result}"

method send*(chan: SigilChanRef, msg: sink Isolated[ThreadSignal]) {.gcsafe, base.} =
  # debugPrint "chan:send: "
  chan[].ch.send(msg)

method tryRecv*(chan: SigilChanRef, dst: var ThreadSignal): bool {.gcsafe, base.} =
  # debugPrint "chan:tryRecv:"
  result = chan[].ch.tryRecv(dst)

method recv*(chan: SigilChanRef): ThreadSignal {.gcsafe, base.} =
  # debugPrint "chan:recv: "
  chan[].ch.recv()

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
    discard
  #   var req = req.deepCopy()
  #   debugPrint "\t proxy:callMethod:remoteSlot: ", "req: ", $req
  #   var msg = isolateRuntime ThreadSignal(kind: Call, slot: localSlot, req: move req, tgt: proxy.Agent.unsafeWeakRef)
  #   debugPrint "\t proxy:callMethod:remoteSlot: ", "msg: ", $msg
  #   debugPrint "\t proxy:callMethod:remoteSlot: ", "proxy: ", proxy.getId()
  #   when defined(sigilsDebug) or defined(debug):
  #     assert proxy.freedByThread == 0
  #   when defined(sigilNonBlockingThreads):
  #     let res = proxy.inbound[].trySend(msg)
  #     if not res:
  #       raise newException(AgentSlotError, "error sending signal to thread")
  #   else:
  #     proxy.msgs[].send(msg)
  elif slot == localSlot:
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
      # let res = proxy.obj.outbound[].trySend(msg)
      # if not res:
      #   raise newException(AgentSlotError, "error sending signal to thread")
      discard
    else:
      debugPrint "\t callMethod:agentProxy:proxyTwin: ", proxy.proxyTwin
      proxy.proxyTwin[].inbox.send(msg)
      withLock proxy.remoteThread[].signaledLock:
        proxy.remoteThread[].signaled.incl(proxy.proxyTwin)
      proxy.remoteThread[].inputs[].send(unsafeIsolate ThreadSignal(kind: Trigger))

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
    if self.listening.len() == 0:
      let
        thr = self.proxyTwin[].remoteThread
        selfRef = self.unsafeWeakRef().asAgent()
      debugPrint "\tproxy:listening:empty: ", self.listening.len()
      try:
        thr[].inputs[].send(unsafeIsolate ThreadSignal(kind: Deref, deref: selfRef))
      except Exception:
        echo "error sending deref message for ", $selfRef

proc newSigilThread*(): SigilThread =
  result = newSharedPtr(isolate SigilThreadObj())
  result[].inputs = newSigilChan()

proc startLocalThread*() =
  if localSigilThread.isNone:
    localSigilThread = some newSigilThread()
    localSigilThread.get()[].id = getThreadId()

proc getCurrentSigilThread*(): SigilThread =
  startLocalThread()
  return localSigilThread.get()

proc exec*[R: SigilThreadBase](thread: var R, sig: ThreadSignal) =
  debugPrint "\nthread got request: ", $sig
  case sig.kind:
  of Move:
    debugPrint "\t threadExec:move: ", $sig.item.getId(), " refcount: ", $sig.item.unsafeGcCount()
    var item = sig.item
    thread.references.incl(item)
  of Deref:
    debugPrint "\t threadExec:deref: ", $sig.deref[].getId(), " refcount: ", $sig.deref[].unsafeGcCount()
    if not sig.deref[].isNil:
      # GC_unref(sig.deref[])
      thread.references.excl(sig.deref[])
  of Call:
    debugPrint "\t threadExec:call: ", $sig.tgt[].getId()
    # for item in thread.references.items():
    #   debugPrint "\t threadExec:refcheck: ", $item.getId(), " rc: ", $item.unsafeGcCount()
    when defined(sigilsDebug) or defined(debug):
      if sig.tgt[].freedByThread != 0:
        echo "exec:call:sig.tgt[].freedByThread:thread: ", $sig.tgt[].freedByThread
        echo "exec:call:sig.req: ", sig.req.repr
        echo "exec:call:thr: ", $getThreadId()
        echo "exec:call: ", $sig.tgt[].getId()
        echo "exec:call:isUnique: ", sig.tgt[].isUniqueRef
        # echo "exec:call:has: ", sig.tgt[] in getCurrentSigilThread()[].references
        # discard c_raise(11.cint)
      assert sig.tgt[].freedByThread == 0
    let res = sig.tgt[].callMethod(sig.req, sig.slot)
    debugPrint "\t threadExec:tgt: ", $sig.tgt[].getId(), " rc: ", $sig.tgt[].unsafeGcCount()
  of Trigger:
    debugPrint "Triggering"
    var signaled: HashSet[WeakRef[AgentProxyShared]]
    withLock thread.signaledLock:
      signaled = move thread.signaled

    for signaled in signaled:
      debugPrint "triggering: ", signaled
      var sig: ThreadSignal
      while signaled[].inbox.tryRecv(sig):
        debugPrint "\t threadExec:tgt: ", $sig.tgt[].getId(), " rc: ", $sig.tgt[].unsafeGcCount()
        let res = sig.tgt[].callMethod(sig.req, sig.slot)

proc poll*[R: SigilThreadBase](thread: var R) =
  let sig = thread.inputs[].recv()
  thread.exec(sig)

proc tryPoll*[R: SigilThreadBase](thread: var R) =
  var sig: ThreadSignal
  if thread.inputs[].tryRecv(sig):
    thread.exec(sig)

proc pollAll*[R: SigilThreadBase](thread: var R): int {.discardable.} =
  var sig: ThreadSignal
  result = 0
  while thread.inputs[].tryRecv(sig):
    thread.exec(sig)
    result.inc()

proc runForever*(thread: SigilThread) =
  while true:
    thread[].poll()

proc runThread*(thread: SigilThread) {.thread.} =
  {.cast(gcsafe).}:
    pcnt.inc
    pidx = pcnt
    assert localSigilThread.isNone()
    localSigilThread = some(thread)
    thread[].id = getThreadId()
    debugPrint "Sigil worker thread waiting!"
    thread.runForever()

proc start*(thread: SigilThread) =
  createThread(thread[].thr, runThread, thread)

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

  # update add proxy to listen to subs which agent was subscribed to
  # so they'll send proxy events which the remote thread will process
  for signal, subscriptions in oldListeningSubs.mpairs():
    for subscription in subscriptions:
      # let tgt = sub.tgt.toRef()
      # brightPrint "moveToThread:oldListeningSubs: ", $subscription.tgt
      subscription.tgt[].addSubscription(signal, localProxy, subscription.slot)

  localProxy.addSubscription(AnySigilName, remoteProxy, remoteSlot)
  remoteProxy.addSubscription(AnySigilName, agentTy, localSlot)

  # # update my subcriptionsTable so I use a new proxy to send events
  # agent[].addSubscription(AnySigilName, remoteProxy, localSlot)
  # remoteProxy.addSubscription(AnySigilName, localProxy, remoteSlot)
  # for signal, subscriberPairs in oldSubscribers.mpairs():
  #   for sub in subscriberPairs:
  #     # echo "signal: ", signal, " subscriber: ", tgt.getId
  #     localProxy.addSubscription(signal, sub.tgt[], sub.slot)

  thread[].inputs[].send(unsafeIsolate ThreadSignal(kind: Move, item: move agentTy))
  thread[].inputs[].send(unsafeIsolate ThreadSignal(kind: Move, item: move remoteProxy))

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
