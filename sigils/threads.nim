import std/sets
import std/isolation
import std/options
import std/locks
import threading/smartptrs

import chans
import isolateutils
import agents
import core

export chans, smartptrs, isolation, isolateutils

type
  SigilChanRef* = ref object of RootObj
    ch*: Chan[ThreadSignal]

  SigilChan* = SharedPtr[SigilChanRef]

  AgentProxyShared* = ref object of Agent
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

proc newSigilChan*(): SigilChan =
  let cref = SigilChanRef.new()
  GC_ref(cref)
  result = newSharedPtr(unsafeIsolate cref)
  result[].ch = newChan[ThreadSignal]()

method trySend*(chan: SigilChanRef, msg: sink Isolated[ThreadSignal]): bool {.gcsafe, base.} =
  echo "REGULAR send try: ", " (th: ", getThreadId(), ")"
  result = chan[].ch.trySend(msg)
  echo "REGULAR send try: res: ", result, " (th: ", getThreadId(), ")"

method send*(chan: SigilChanRef, msg: sink Isolated[ThreadSignal]) {.gcsafe, base.} =
  echo "REGULAR send: ", " (th: ", getThreadId(), ")"
  chan[].ch.send(msg)

method tryRecv*(chan: SigilChanRef, dst: var ThreadSignal): bool {.gcsafe, base.} =
  echo "REGULAR recv try: ", " (th: ", getThreadId(), ")"
  result = chan[].ch.tryRecv(dst)

method recv*(chan: SigilChanRef): ThreadSignal {.gcsafe, base.} =
  echo "REGULAR recv: ", " (th: ", getThreadId(), ")"
  chan[].ch.recv()

proc remoteSlot*(context: Agent, params: SigilParams) {.nimcall.} =
  raise newException(AssertionDefect, "this should never be called!")
proc localSlot*(context: Agent, params: SigilParams) {.nimcall.} =
  raise newException(AssertionDefect, "this should never be called!")

method callMethod*(
    proxy: AgentProxyShared, req: SigilRequest, slot: AgentProc
): SigilResponse {.gcsafe, effectsOf: slot.} =
  ## Route's an rpc request. 
  echo "threaded Agent!", " (th: ", getThreadId(), ")"
  if slot == remoteSlot:
    var msg = unsafeIsolate ThreadSignal(kind: Call, slot: localSlot, req: req, tgt: proxy.Agent.unsafeWeakRef)
    echo "\texecuteRequest:agentProxy:remoteSlot: ", "req: ", req
    # echo "\texecuteRequest:agentProxy: ", "inbound: ", $proxy.inbound, " proxy: ", proxy.getId()
    let res = proxy.inbound[].trySend(msg)
    if not res:
      raise newException(AgentSlotError, "error sending signal to thread")
  elif slot == localSlot:
    echo "\texecuteRequest:agentProxy:localSlot: ", "req: ", req
    # echo "\texecuteRequest:agentProxy: ", "inbound: ", $proxy.inbound, " proxy: ", proxy.getId()
    callSlots(proxy, req)
  else:
    var msg = unsafeIsolate ThreadSignal(kind: Call, slot: slot, req: req, tgt: proxy.remote)
    echo "\texecuteRequest:agentProxy:other: ", "outbound: ", proxy.outbound.repr
    let res = proxy.outbound[].trySend(msg)
    if not res:
      raise newException(AgentSlotError, "error sending signal to thread")

method removeSubscriptionsFor*(
    self: AgentProxyShared, subscriber: WeakRef[Agent]
) {.gcsafe, raises: [].} =
  echo "removeSubscriptionsFor:proxy:", " self:id: ", $self.getId()
  withLock self.lock:
    echo "removeSubscriptionsFor:proxy:ready:", " self:id: ", $self.getId()
    removeSubscriptionsForImpl(self, subscriber)

method unregisterSubscriber*(
    self: AgentProxyShared, listener: WeakRef[Agent]
) {.gcsafe, raises: [].} =
  echo "unregisterSubscriber:proxy:", " self:id: ", $self.getId()
  withLock self.lock:
    echo "unregisterSubscriber:proxy:ready:", " self:id: ", $self.getId()
    unregisterSubscriberImpl(self, listener)

proc newSigilThread*(): SigilThread =
  result = newSharedPtr(isolate SigilThreadObj())
  result[].inputs = newSigilChan()

proc poll*[R: SigilThreadBase](thread: var R, sig: ThreadSignal) =
  echo "thread got request: ", sig, " (th: ", getThreadId(), ")"
  case sig.kind:
  of Move:
    var item = sig.item
    thread.references.incl(item)
  of Deref:
    thread.references.excl(sig.deref.toRef)
  of Call:
    echo "call: ", sig.tgt[].getId()
    discard sig.tgt[].callMethod(sig.req, sig.slot)

proc poll*[R: SigilThreadBase](thread: var R) =
  let sig = thread.inputs[].recv()
  thread.poll(sig)

proc execute*(thread: SigilThread) =
  while true:
    thread[].poll()

proc runThread*(thread: SigilThread) {.thread.} =
  {.cast(gcsafe).}:
    assert localSigilThread.isNone()
    localSigilThread = some(thread)
    echo "Sigil worker thread waiting!", " (", getThreadId(), ")"
    thread.execute()

proc start*(thread: SigilThread) =
  createThread(thread[].thr, runThread, thread)

proc startLocalThread*() =
  if localSigilThread.isNone:
    localSigilThread = some newSigilThread()

proc getCurrentSigilThread*(): SigilThread =
  startLocalThread()
  return localSigilThread.get()

proc findSubscribedToSignals(
    subscribedTo: HashSet[WeakRef[Agent]], xid: WeakRef[Agent]
): Table[SigilName, OrderedSet[Subscription]] =
  ## remove myself from agents I'm subscribed to
  for obj in subscribedTo:
    echo "freeing subscribed: ", obj[].getId()
    var toAdd = initOrderedSet[Subscription]()
    for signal, subscriberPairs in obj[].subscribers.mpairs():
      for item in subscriberPairs:
        if item.tgt == xid:
          toAdd.incl(Subscription(tgt: obj, slot: item.slot))
          # echo "agentRemoved: ", "tgt: ", xid.toPtr.repr, " id: ", agent.debugId, " obj: ", obj[].debugId, " name: ", signal
      result[signal] = move toAdd

proc moveToThread*[T: Agent, R: SigilThreadBase](
    agentTy: T,
    thread: SharedPtr[R]
): AgentProxy[T] =
  ## move agent to another thread
  if not isUniqueRef(agentTy):
    raise newException(
      AccessViolationDefect,
      "agent must be unique and not shared to be passed to another thread!",
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
      let tgt = sub.tgt.toRef()
      tgt.addSubscription(signal, proxy, sub.slot)

  # update my subscribers so I use a new proxy to send events
  # to them
  agent[].addSubscription(AnySigilName, proxy, remoteSlot)
  for signal, subscriberPairs in oldSubscribers.mpairs():
    for sub in subscriberPairs:
      # echo "signal: ", signal, " subscriber: ", tgt.getId
      proxy.addSubscription(signal, sub.tgt.toRef, sub.slot)
  
  thread[].inputs[].send(unsafeIsolate ThreadSignal(kind: Move, item: agentTy))

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
