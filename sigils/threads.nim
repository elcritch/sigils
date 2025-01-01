import std/sets
import std/isolation
import std/options
import std/locks
import threading/smartptrs

import chans
import isolateutils
import agents
import core

from system/ansi_c import c_raise

export chans, smartptrs, isolation, isolateutils

type
  SigilChanRef* = ref object of RootObj
    ch*: Chan[ThreadSignal]

  SigilChan* = SharedPtr[SigilChanRef]

  # AgentProxySharedObj* = object

  AgentProxyShared* = ref object of Agent
    # obj*: AgentProxySharedObj
    remote*: WeakRef[Agent]
    outbound*: SigilChan
    inbound*: SigilChan
    listeners*: HashSet[Agent]
    lock*: Lock

  AgentProxy*[T] = ref object of AgentProxyShared

  ThreadSignalKind* {.pure.} = enum
    Call
    Move
    Deref

  ThreadSignal* = object
    case kind*: ThreadSignalKind
    of Call:
      slot*: AgentProc
      req*: SigilRequest
      tgt*: WeakRef[Agent]
    of Move:
      item*: Agent
    of Deref:
      deref*: WeakRef[Agent]

  SigilThreadBase* = object of RootObj
    inputs*: SigilChan
    references*: HashSet[Agent]

  SigilThreadObj* = object of SigilThreadBase
    thr*: Thread[SharedPtr[SigilThreadObj]]

  SigilThread* = SharedPtr[SigilThreadObj]

var localSigilThread {.threadVar.}: Option[SigilThread]

proc `=destroy`*(obj: var typeof(AgentProxyShared()[])) =
  debugPrint "PROXY Destroy: 0x", addr(obj).pointer.repr
  `=destroy`(obj.remote)
  `=destroy`(obj.outbound)
  `=destroy`(obj.inbound)
  `=destroy`(obj.listeners)
  `=destroy`(obj.lock)

  # careful on this one -- should probably figure out a test
  # in case the compiler ever changes
  `=destroy`(toAgentObj(cast[AgentProxyShared](addr obj)))

proc newSigilChan*(): SigilChan =
  let cref = SigilChanRef.new()
  GC_ref(cref)
  result = newSharedPtr(unsafeIsolate cref)
  result[].ch = newChan[ThreadSignal](1_000)

method trySend*(chan: SigilChanRef, msg: sink Isolated[ThreadSignal]): bool {.gcsafe, base.} =
  debugPrint &"REGULAR send try:"
  result = chan[].ch.trySend(msg)
  debugPrint &"REGULAR send try: res: {$result}"

method send*(chan: SigilChanRef, msg: sink Isolated[ThreadSignal]) {.gcsafe, base.} =
  debugPrint "REGULAR send: "
  chan[].ch.send(msg)

method tryRecv*(chan: SigilChanRef, dst: var ThreadSignal): bool {.gcsafe, base.} =
  debugPrint "REGULAR recv try:"
  result = chan[].ch.tryRecv(dst)

method recv*(chan: SigilChanRef): ThreadSignal {.gcsafe, base.} =
  debugPrint "REGULAR recv: "
  chan[].ch.recv()

proc remoteSlot*(context: Agent, params: SigilParams) {.nimcall.} =
  raise newException(AssertionDefect, "this should never be called!")
proc localSlot*(context: Agent, params: SigilParams) {.nimcall.} =
  raise newException(AssertionDefect, "this should never be called!")

method callMethod*(
    proxy: AgentProxyShared, req: SigilRequest, slot: AgentProc
): SigilResponse {.gcsafe, effectsOf: slot.} =
  ## Route's an rpc request. 
  debugPrint "callMethod: proxy: ", $proxy.getId(), " refcount: ", proxy.unsafeGcCount()
  if slot == remoteSlot:
    var req = req.deepCopy()
    debugPrint "\t proxy:callMethod:remoteSlot: ", "req: ", $req
    var msg = isolateRuntime ThreadSignal(kind: Call, slot: localSlot, req: move req, tgt: proxy.Agent.unsafeWeakRef)
    debugPrint "\t proxy:callMethod:remoteSlot: ", "msg: ", $msg
    debugPrint "\t proxy:callMethod:remoteSlot: ", "proxy: ", proxy.getId()
    when defined(sigilDebugFreed) or defined(debug):
      assert proxy.freed == 0
    when defined(sigilNonBlockingThreads):
      let res = proxy.inbound[].trySend(msg)
      if not res:
        raise newException(AgentSlotError, "error sending signal to thread")
    else:
      proxy.inbound[].send(msg)
  elif slot == localSlot:
    debugPrint "\t callMethod:agentProxy:localSlot: ", "req: ", $req
    callSlots(proxy, req)
  else:
    var req = req.deepCopy()
    # echo "proxy:callMethod: ", " proxy:refcount: ", proxy.unsafeGcCount()
    # echo "proxy:callMethod: ", " proxy.obj.remote:refcount: ", proxy.obj.remote[].unsafeGcCount()
    debugPrint "\t callMethod:agentProxy:InitCall:", "Outbound: ", req.procName, " proxy:remote:obj: ", proxy.remote.getId()
    var msg = isolateRuntime ThreadSignal(kind: Call, slot: slot, req: move req, tgt: proxy.remote)
    when defined(sigilNonBlockingThreads):
      let res = proxy.obj.outbound[].trySend(msg)
      if not res:
        raise newException(AgentSlotError, "error sending signal to thread")
    else:
      proxy.outbound[].send(msg)

method removeSubscriptionsFor*(
    self: AgentProxyShared, subscriber: WeakRef[Agent]
) {.gcsafe, raises: [].} =
  debugPrint "removeSubscriptionsFor:proxy:", " self:id: ", $self.getId()
  withLock self.lock:
    # block:
    debugPrint "removeSubscriptionsFor:proxy:ready:", " self:id: ", $self.getId()
    removeSubscriptionsForImpl(self, subscriber)

method unregisterSubscriber*(
    self: AgentProxyShared, listener: WeakRef[Agent]
) {.gcsafe, raises: [].} =
  debugPrint "unregisterSubscriber:proxy:", " self:id: ", $self.getId()
  withLock self.lock:
    # block:
    debugPrint "unregisterSubscriber:proxy:ready:", " self:id: ", $self.getId()
    unregisterSubscriberImpl(self, listener)

proc newSigilThread*(): SigilThread =
  result = newSharedPtr(isolate SigilThreadObj())
  result[].inputs = newSigilChan()

proc startLocalThread*() =
  if localSigilThread.isNone:
    localSigilThread = some newSigilThread()

proc getCurrentSigilThread*(): SigilThread =
  startLocalThread()
  return localSigilThread.get()

proc exec*[R: SigilThreadBase](thread: var R, sig: ThreadSignal) =
  debugPrint "thread got request: ", $sig
  case sig.kind:
  of Move:
    debugPrint "\t threadExec:move: ", $sig.item.getId(), " refcount: ", $sig.item.unsafeGcCount()
    var item = sig.item
    thread.references.incl(item)
  of Deref:
    debugPrint "\t threadExec:deref: ", $sig.deref[].getId(), " refcount: ", $sig.deref[].unsafeGcCount()
    thread.references.excl(sig.deref[])
  of Call:
    debugPrint "\t threadExec:call: ", $sig.tgt[].getId()
    for item in thread.references.items():
      debugPrint "\t threadExec:refcheck: ", $item.getId(), " rc: ", $item.unsafeGcCount()
    when defined(sigilDebugFreed) or defined(debug):
      if sig.tgt[].freed != 0:
        echo "exec:call:sig.tgt[].freed:thread: ", $sig.tgt[].freed
        echo "exec:call:sig.req: ", sig.req.repr
        echo "exec:call:thr: ", $getThreadId()
        echo "exec:call: ", $sig.tgt[].getId()
        echo "exec:call:isUnique: ", sig.tgt[].isUniqueRef
        echo "exec:call:has: ", sig.tgt[] in getCurrentSigilThread()[].references
        discard c_raise(11.cint)
      assert sig.tgt[].freed == 0
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
    debugPrint "Sigil worker thread waiting!"
    thread.runForever()

proc start*(thread: SigilThread) =
  createThread(thread[].thr, runThread, thread)

proc findSubscribedToSignals(
    subscribedTo: HashSet[WeakRef[Agent]], xid: WeakRef[Agent]
): Table[SigilName, OrderedSet[Subscription]] =
  ## remove myself from agents I'm subscribed to
  for obj in subscribedTo:
    debugPrint "freeing subscribed: ", $obj[].getId()
    var toAdd = initOrderedSet[Subscription]()
    for signal, subscriberPairs in obj[].subscribers.mpairs():
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
  let
    ct = getCurrentSigilThread()
    agent = agentTy.unsafeWeakRef.asAgent()
    proxy = AgentProxy[T](
        remote: agent,
        outbound: thread[].inputs,
        inbound: ct[].inputs,
    )
  proxy.lock.initLock()

  # handle things subscribed to `agent`, ie the inverse
  var
    oldSubscribers = agent[].subscribers
    oldSubscribedTo = agent[].subscribedTo.findSubscribedToSignals(agent[].unsafeWeakRef)

  agent[].subscribedTo.unsubscribe(agent)
  agent[].subscribers.removeSubscription(agent)

  agent[].subscribedTo.clear()
  agent[].subscribers.clear()

  # update add proxy to listen to agents I am subscribed to
  # so they'll send my proxy events which the remote thread
  # will process
  for signal, subscriberPairs in oldSubscribedTo.mpairs():
    for sub in subscriberPairs:
      # let tgt = sub.tgt.toRef()
      sub.tgt[].addSubscription(signal, proxy, sub.slot)

  # update my subscribers so I use a new proxy to send events
  # to them
  agent[].addSubscription(AnySigilName, proxy, remoteSlot)
  for signal, subscriberPairs in oldSubscribers.mpairs():
    for sub in subscriberPairs:
      # echo "signal: ", signal, " subscriber: ", tgt.getId
      proxy.addSubscription(signal, sub.tgt[], sub.slot)
  
  thread[].inputs[].send(unsafeIsolate ThreadSignal(kind: Move, item: move agentTy))
  # thread[].inputs[].send(unsafeIsolate ThreadSignal(kind: Move, item: proxy))

  return proxy


template connect*[T, S](
    a: Agent,
    signal: typed,
    b: AgentProxy[T],
    slot: Signal[S],
    acceptVoidSlot: static bool = false,
): void =
  ## connects `AgentProxy[T]` to remote signals
  ## 
  checkSignalTypes(a, signal, T(), slot, acceptVoidSlot)
  a.addSubscription(signalName(signal), b, slot)

template connect*[T](
    a: Agent,
    signal: typed,
    b: AgentProxy[T],
    slot: typed,
    acceptVoidSlot: static bool = false,
): void =
  ## connects `AgentProxy[T]` to remote signals
  ## 
  checkSignalThreadSafety(SignalTypes.`signal`(typeof(a)))
  let agentSlot = `slot`(T)
  checkSignalTypes(a, signal, T(), agentSlot, acceptVoidSlot)
  a.addSubscription(signalName(signal), b, agentSlot)

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
  let ct = getCurrentSigilThread()
  let proxy = Agent(proxyTy)
  # let bref = unsafeWeakRef[Agent](b)
  # proxy.extract()[].addSubscription(signalName(signal), proxy, slot)
  proxy.addSubscription(signalName(signal), b, slot)

  # thread[].inputs.send( unsafeIsolate ThreadSignal(kind: Register, shared: ensureMove agent))

  # TODO: This is wrong! but I wanted to get something running...
  # ct[].proxies.incl(proxy)
