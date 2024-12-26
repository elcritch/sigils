import std/sets
import std/isolation
import std/options
import std/locks
import threading/smartptrs
import threading/channels

import isolateutils
import agents
import core

export channels, smartptrs, isolation, isolateutils

type
  AgentProxyShared* = ref object of Agent
    remote*: WeakRef[Agent]
    outbound*: Chan[ThreadSignal]
    inbound*: Chan[ThreadSignal]
    listeners*: HashSet[Agent]
    lock*: Lock

  AgentProxy*[T] = ref object of AgentProxyShared

  ThreadSignalKind* {.pure.} = enum
    Call
    Register
    UnRegister
    
  ThreadSignal* = object
    case kind*: ThreadSignalKind
    of Call:
      slot*: AgentProc
      req*: SigilRequest
      tgt*: WeakRef[Agent]
    of Register:
      shared*: WeakRef[Agent]
    of UnRegister:
      unshared*: WeakRef[Agent]

  SigilThreadObj* = object of Agent
    thread*: Thread[SharedPtr[SigilThreadObj]]
    inputs*: Chan[ThreadSignal]
    # proxies*: HashSet[AgentProxyShared]
    references*: HashSet[Agent]

  SigilThread* = SharedPtr[SigilThreadObj]

var localSigilThread {.threadVar.}: Option[SigilThread]

proc remoteSlot*(context: Agent, params: SigilParams) {.nimcall.} =
  raise newException(AssertionDefect, "this should never be called!")
proc localSlot*(context: Agent, params: SigilParams) {.nimcall.} =
  raise newException(AssertionDefect, "this should never be called!")

method callMethod*(
    proxy: AgentProxyShared, req: SigilRequest, slot: AgentProc
): SigilResponse {.gcsafe, effectsOf: slot.} =
  ## Route's an rpc request. 
  echo "threaded Agent!"
  if slot == remoteSlot:
    let sig = ThreadSignal(kind: Call, slot: localSlot, req: req, tgt: proxy.Agent.unsafeWeakRef)
    echo "executeRequest:agentProxy: ", "req: ", req
    echo "executeRequest:agentProxy: ", "inbound: ", $proxy.inbound, " proxy: ", proxy.getId()
    let res = proxy.inbound.trySend(unsafeIsolate sig)
    if not res:
      raise newException(AgentSlotError, "error sending signal to thread")
  elif slot == localSlot:
    echo "executeRequest:agentProxy: ", "req: ", req
    echo "executeRequest:agentProxy: ", "inbound: ", $proxy.inbound, " proxy: ", proxy.getId()
    callSlots(proxy, req)
  else:
    let sig = ThreadSignal(kind: Call, slot: slot, req: req, tgt: proxy.remote)
    echo "executeRequest:agentProxy: ", "outbound: ", $proxy.outbound
    let res = proxy.outbound.trySend(unsafeIsolate sig)
    if not res:
      raise newException(AgentSlotError, "error sending signal to thread")

proc newSigilThread*(): SigilThread =
  result = newSharedPtr(SigilThreadObj())
  result[].inputs = newChan[ThreadSignal]()

proc poll*(thread: SigilThread) =
  let sig = thread[].inputs.recv()
  echo "thread got request: ", sig, " (th: ", getThreadId(), ")"
  case sig.kind:
  of Register:
    thread[].references.incl(sig.shared.toRef)
  of UnRegister:
    thread[].references.excl(sig.unshared.toRef)
  of Call:
    echo "call: ", sig.tgt[].getId()
    discard sig.tgt[].callMethod(sig.req, sig.slot)

proc execute*(thread: SigilThread) =
  while true:
    thread.poll()

proc runThread*(thread: SigilThread) {.thread.} =
  {.cast(gcsafe).}:
    assert localSigilThread.isNone()
    localSigilThread = some(thread)
    echo "Sigil worker thread waiting!", " (", getThreadId(), ")"
    thread.execute()

proc start*(thread: SigilThread) =
  createThread(thread[].thread, runThread, thread)

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
  # echo "subscribed: ", xid[].subscribed.toSeq.mapIt(it[].debugId).repr
  for obj in subscribedTo:
    # echo "freeing subscribed: ", obj[].debugId
    var toAdd = initOrderedSet[Subscription]()
    for signal, subscriberPairs in obj[].subscribers.mpairs():
      for item in subscriberPairs:
        if item.tgt == xid:
          toAdd.incl(Subscription(tgt: obj, slot: item.slot))
          # echo "agentRemoved: ", "tgt: ", xid.toPtr.repr, " id: ", agent.debugId, " obj: ", obj[].debugId, " name: ", signal
      result[signal] = move toAdd

proc moveToThread*[T: Agent](agentTy: T, thread: SigilThread): AgentProxy[T] =
  if not isUniqueRef(agentTy):
    raise newException(
      AccessViolationDefect,
      "agent must be unique and not shared to be passed to another thread!",
    )

  let
    ct = getCurrentSigilThread()
    agent = Agent(agentTy)
    agentRef = agent.unsafeWeakRef()
    proxy = AgentProxy[T](
      remote: agentRef,
      outbound: thread[].inputs,
      inbound: ct[].inputs,
    )

  # handle things subscribed to `agent`, ie the inverse
  var
    oldSubscribers = agent.subscribers
    oldSubscribedTo = agent.subscribedTo.findSubscribedToSignals(agent.unsafeWeakRef)

  agent.subscribedTo.unsubscribe(agent.unsafeWeakRef)
  agent.subscribers.removeSubscription(agent.unsafeWeakRef)

  agent.subscribedTo.clear()
  agent.subscribers.clear()

  # update add proxy to listen to agents I am subscribed to
  # so they'll send my proxy events which the remote thread
  # will process
  for signal, subscriberPairs in oldSubscribedTo.mpairs():
    for sub in subscriberPairs:
      let tgt = sub.tgt.toRef()
      tgt.addSubscription(signal, proxy, sub.slot)

  # update my subscribers so I use a new proxy to send events
  # to them
  for signal, subscriberPairs in oldSubscribers.mpairs():
    for sub in subscriberPairs:
      # echo "signal: ", signal, " subscriber: ", tgt.getId
      proxy.addSubscription(signal, sub.tgt.toRef, sub.slot)
      agent.addSubscription(signal, proxy, remoteSlot)
  
  thread[].inputs.send(unsafeIsolate ThreadSignal(kind: Register, shared: ensureMove agentRef))

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
    a: AgentProxy[T],
    signal: typed,
    b: Agent,
    slot: Signal[S],
    acceptVoidSlot: static bool = false,
): void =
  ## connects `AgentProxy[T]` to remote signals
  ## 
  {.error: "TODO".}
  checkSignalTypes(T(), signal, b, slot, acceptVoidSlot)
  let ct = getCurrentSigilThread()
  let bref = unsafeWeakRef[Agent](b)
  let proxy = AgentProxy[typeof(b)](
    outbound: ct[].inputs, remote: isolate bref
  )
  a.remote.extract()[].addSubscription(signalName(signal), proxy, slot)

  # thread[].inputs.send( unsafeIsolate ThreadSignal(kind: Register, shared: ensureMove agent))

  # TODO: This is wrong! but I wanted to get something running...
  # ct[].proxies.incl(proxy)
