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
    remote*: SharedPtr[Agent]
    chan*: Chan[ThreadSignal]
    listeners*: HashSet[SharedPtr[Agent]]
    lock*: Lock

  AgentProxy*[T] = ref object of AgentProxyShared

  ThreadSignal* = object
    slot*: AgentProc
    req*: SigilRequest
    tgt*: SharedPtr[Agent]

  SigilThreadObj* = object of Agent
    thread*: Thread[Chan[ThreadSignal]]
    inputs*: Chan[ThreadSignal]
    proxies*: HashSet[AgentProxyShared]
    references*: HashSet[SharedPtr[Agent]]

  SigilThread* = SharedPtr[SigilThreadObj]

method callMethod*(
    ctx: AgentProxyShared, req: SigilRequest, slot: AgentProc
): SigilResponse {.gcsafe, effectsOf: slot.} =
  ## Route's an rpc request. 
  # echo "threaded Agent!"
  let proxy = ctx
  let sig = ThreadSignal(slot: slot, req: req, tgt: proxy.remote)
  # echo "executeRequest:agentProxy: ", "chan: ", $proxy.chan
  let res = proxy.chan.trySend(unsafeIsolate sig)
  if not res:
    raise newException(AgentSlotError, "error sending signal to thread")

proc newSigilThread*(): SigilThread =
  result = newSharedPtr(SigilThreadObj())
  result[].inputs = newChan[ThreadSignal]()

proc poll*(inputs: Chan[ThreadSignal]) =
  let sig = inputs.recv()
  # echo "thread got request: ", sig, " (", getThreadId(), ")"
  discard sig.tgt[].callMethod(sig.req, sig.slot)

proc poll*(thread: SigilThread) =
  thread[].inputs.poll()

proc execute*(inputs: Chan[ThreadSignal]) =
  while true:
    poll(inputs)

proc execute*(thread: SigilThread) =
  thread[].inputs.execute()

proc runThread*(inputs: Chan[ThreadSignal]) {.thread.} =
  {.cast(gcsafe).}:
    var inputs = inputs
    echo "Sigil worker thread waiting!", " (", getThreadId(), ")"
    inputs.execute()

proc start*(thread: SigilThread) =
  createThread(thread[].thread, runThread, thread[].inputs)

var sigilThread {.threadVar.}: Option[SigilThread]

proc startLocalThread*() =
  if sigilThread.isNone:
    sigilThread = some newSigilThread()

proc getCurrentSigilThread*(): SigilThread =
  startLocalThread()
  return sigilThread.get()

proc findSubscribedToSignals(
    subscribedTo: HashSet[WeakRef[Agent]], xid: WeakRef[Agent]
): Table[SigilName, OrderedSet[AgentPairing]] =
  ## remove myself from agents I'm subscribed to
  # echo "subscribed: ", xid[].subscribed.toSeq.mapIt(it[].debugId).repr
  for obj in subscribedTo:
    # echo "freeing subscribed: ", obj[].debugId
    var toAdd = initOrderedSet[AgentPairing]()
    for signal, subscriberPairs in obj[].subscribers.mpairs():
      for item in subscriberPairs:
        if item.tgt == xid:
          toAdd.incl((tgt: obj, fn: item.fn))
          # echo "agentRemoved: ", "tgt: ", xid.toPtr.repr, " id: ", agent.debugId, " obj: ", obj[].debugId, " name: ", signal
      result[signal] = move toAdd

proc moveToThread*[T: Agent](agent: T, thread: SigilThread): AgentProxy[T] =
  if not isUniqueRef(agent):
    raise newException(
      AccessViolationDefect,
      "agent must be unique and not shared to be passed to another thread!",
    )

  result = AgentProxy[T](
    remote: newSharedPtr(unsafeIsolate(Agent(agent))), chan: thread[].inputs
  )

  let self = Agent(agent)

  # handle things subscribed to `agent`, ie the inverse
  var
    oldSubscribers = agent.subscribers
    oldSubscribedTo = agent.subscribedTo.findSubscribedToSignals(self.unsafeWeakRef)

  agent.subscribedTo.unsubscribe(self.unsafeWeakRef)
  agent.subscribers.removeSubscription(self.unsafeWeakRef)

  agent.subscribedTo.clear()
  agent.subscribers.clear()

  # update add proxy to listen to agents I am subscribed to
  # so they'll send my proxy events which the remote thread
  # will process
  for signal, subscriberPairs in oldSubscribedTo.mpairs():
    for (src, slot) in subscriberPairs:
      src.toRef().addAgentListeners(signal, result, slot)

  # update my subscribers so I use a new proxy to send events
  # to them
  let ct = getCurrentSigilThread()
  for signal, subscriberPairs in oldSubscribers.mpairs():
    for (sub, slot) in subscriberPairs:
      # echo "signal: ", signal, " subscriber: ", tgt.getId
      let subproxy =
        AgentProxyShared(chan: ct[].inputs,
                         remote: newSharedPtr(unsafeIsolate sub[]))
      self.addAgentListeners(signal, subproxy, slot)
      # # TODO: This is wrong! but I wanted to get something running...
      ct[].proxies.incl(subproxy)


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
  a.addAgentListeners(signalName(signal), b, slot)

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
  a.addAgentListeners(signalName(signal), b, agentSlot)

template connect*[T, S](
    a: AgentProxy[T],
    signal: typed,
    b: Agent,
    slot: Signal[S],
    acceptVoidSlot: static bool = false,
): void =
  ## connects `AgentProxy[T]` to remote signals
  ## 
  checkSignalTypes(T(), signal, b, slot, acceptVoidSlot)
  let ct = getCurrentSigilThread()
  let proxy = AgentProxy[typeof(b)](
    chan: ct[].inputs, remote: newSharedPtr(unsafeIsolate Agent(b))
  )
  a.remote[].addAgentListeners(signalName(signal), proxy, slot)
  # TODO: This is wrong! but I wanted to get something running...
  ct[].proxies.incl(proxy)
