import std/sets
import std/isolation
import std/options
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

template checkThreadSafety(sig: object, parent: typed) =
  discard
  echo "CHECK: ok object"
  # {.error: "error!".}
template checkThreadSafety(sig: ref, parent: typed) =
  discard
  echo "CHECK: ok ref"
  {.error: "Signal type with ref's aren't thread safe! Signal type: " & $(typeof(parent)).}

template checkThreadSafety[T](sig: T, parent: typed) =
  discard
  echo "CHECK: ok other"

template checkSignalThreadSafety(sig: typed) =
  discard
  echo "CHECK: ", sig.typeof.repr, " :: ", sig.repr
  for n, v in sig.fieldPairs():
    echo "CHECK: ", n, " ", v.typeof.repr, " v: ", v.repr
    checkThreadSafety(v, sig)


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

proc moveToThread*[T: Agent](agent: T, thread: SigilThread): AgentProxy[T] =
  if not isUniqueRef(agent):
    raise newException(
      AccessViolationDefect,
      "agent must be unique and not shared to be passed to another thread!",
    )

  return AgentProxy[T](
    remote: newSharedPtr(unsafeIsolate(Agent(agent))), chan: thread[].inputs
  )

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

  # TODO: does this *really* work? It feels off but I wanted to
  #       get it running something. Surprisingly haven't seen any
  #       bugs with it so far, but it's sus.
  let proxy =
    AgentProxy[typeof(b)](chan: ct[].inputs, remote: newSharedPtr(unsafeIsolate Agent(b)))
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
    # echo "sigil thread waiting!", " (", getThreadId(), ")"
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
