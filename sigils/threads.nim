import std/sets
import std/isolation
import std/options
import std/sequtils
import threading/smartptrs
import threading/channels

import agents
import core

export channels, smartptrs, isolation

type
  AgentProxyShared* = ref object of Agent
    remote*: SharedPtr[Agent]
    chan*: Chan[ThreadSignal]

  AgentProxy*[T] = ref object of AgentProxyShared

  ThreadSignal* = object
    slot*: AgentProc
    req*: SigilRequest
    tgt*: SharedPtr[Agent]

  SigilThreadObj* = object of Agent
    thread*: Thread[Chan[ThreadSignal]]
    inputs*: Chan[ThreadSignal]

  SigilThread* = SharedPtr[SigilThreadObj]

template checkThreadSafety(field: object, parent: typed) =
  discard

template checkThreadSafety[T](field: Isolated[T], parent: typed) =
  discard

template checkThreadSafety(field: ref, parent: typed) =
  {.
    error:
      "Signal type with ref's aren't thread safe! Signal type: " & $(typeof(parent)) &
      ". Use `Isolate[" & $(typeof(field)) & "]` to use it."
  .}

template checkThreadSafety[T](field: T, parent: typed) =
  discard

template checkSignalThreadSafety(sig: typed) =
  for n, v in sig.fieldPairs():
    checkThreadSafety(v, sig)

type IsolateError* = object of CatchableError

template verifyUnique[T](field: T) =
  discard

template verifyUnique(field: ref) =
  if not field.isUniqueRef():
    raise newException(IsolateError, "reference not unique! Cannot safely isolate it")
  for v in field[].fields():
    verifyUnique(v)

template verifyUnique[T: tuple | object](field: T) =
  for n, v in field.fieldPairs():
    checkThreadSafety(v, sig)

proc tryIsolate*[T](field: T): Isolated[T] {.raises: [IsolateError].} =
  ## Isolates a ref type or type with ref's and ensure that
  ## each ref is unique. This allows safely isolating it.
  verifyUnique(field)

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
  # TODO: does this *really* work? It feels off but I wanted to
  #       get it running something. Surprisingly haven't seen any
  #       bugs with it so far, but it's sus.
  let ct = getCurrentSigilThread()
  let proxy = AgentProxy[typeof(b)](
    chan: ct[].inputs, remote: newSharedPtr(unsafeIsolate Agent(b))
  )
  a.remote[].addAgentListeners(signalName(signal), proxy, slot)

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
    echo "sigil thread waiting!", " (", getThreadId(), ")"
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

proc resubscribe(subscribedTo: HashSet[WeakRef[Agent]], xid, proxy: WeakRef[Agent]) =
  ## remove myself from agents I'm subscribed to
  # echo "subscribed: ", xid[].subscribed.toSeq.mapIt(it[].debugId).repr
  var toDel: seq[AgentPairing]
  for obj in subscribedTo:
    # echo "freeing subscribed: ", obj[].debugId
    for signal, subscriberPairs in obj[].subscribers.mpairs():
      toDel.setLen(0)
      for item in subscriberPairs:
        if item.tgt == xid:
          toDel.add(item)
      for item in toDel:
        echo "agentReSubscribe: ", "tgt: ", xid.getId, " obj: ", obj.getId, " name: ", signal
        subscriberPairs.excl(item)
        let curr = (tgt: proxy, fn: item.fn)
        subscriberPairs.incl(curr)
        # echo "agentReSubscribed: ", "tgt: ", xid.toPtr.repr, " id: ", agent.debugId, " obj: ", obj[].debugId, " name: ", signal

proc moveTo[T](
    subscribers: var Table[SigilName, OrderedSet[AgentPairing]], xid, proxy: WeakRef[Agent], self: var AgentProxy[T]
) =
  ## remove myself from agents listening to me
  echo "moveTo:self: ", xid.getId

  for signal, subscriberPairs in subscribers.mpairs():
    # echo "freeing signal: ", signal, " subscribers: ", subscriberPairs
    var newSubscriberPairs = initOrderedSet[AgentPairing]()
    for subscriberPair in subscriberPairs:
      # echo "\tlisterners: ", subscriber.tgt
      let b = subscriberPair.tgt[]
      echo "\tlisterners:subscribed ", b.subscribedTo.mapIt(it.getId)
      b.subscribedTo.excl(xid)
      b.subscribedTo.incl(proxy)
      echo "\tlisterners:subscribed:post: ", b.subscribedTo.mapIt(it.getId)

      let ct = getCurrentSigilThread()
      let slot = subscriberPair.fn
      let remoteProxy = AgentProxy[typeof(b)](
        chan: ct[].inputs, remote: newSharedPtr(unsafeIsolate b)
      )
      let pairing: AgentPairing = (tgt: self.remote[].unsafeWeakRef, fn: slot)
      newSubscriberPairs.incl(pairing)
      # self.remote[].addAgentListeners(signal, remoteProxy, slot)
      echo "\tlisterners:subscriber: b: ", b.getId, " rproxy: ", remoteProxy.getId
    
    subscriberPairs = newSubscriberPairs

proc findSubscribedToSignals*(
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

  let
    self = Agent(agent)
    proxy = Agent(result).unsafeWeakRef()

  echo "moving agent: ", self.getId, " to proxy: ", proxy.getId()

  var
    oldSubscribers = agent.subscribers
    oldSubscribedTo = agent.subscribedTo.findSubscribedToSignals(self.unsafeWeakRef)

  agent.subscribedTo.unsubscribe(self.unsafeWeakRef)
  agent.subscribers.remove(self.unsafeWeakRef)

  agent.subscribedTo.clear()
  agent.subscribers.clear()

  for signal, subscriberPairs in oldSubscribers.mpairs():
    for subscriberPair in subscriberPairs:
      let (tgt, slot) = subscriberPair
      echo "signal: ", signal, " subscriber: ", tgt.getId
      self.addAgentListeners(signal, tgt.toRef(), slot)

  for signal, subscriberPairs in oldSubscribedTo.mpairs():
    for subscriberPair in subscriberPairs:
      let (src, slot) = subscriberPair
      src.toRef().addAgentListeners(signal, result, slot)

  # a.addAgentListeners(signalName(signal), b, agentSlot)
  # a.remote[].addAgentListeners(signalName(signal), proxy, slot)
