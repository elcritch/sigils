import std/sets
import std/isolation
import agents
import threading/smartptrs
import threading/channels

export channels, smartptrs, isolation

type
  ThreadSignal* = object
    slot*: AgentProc
    req*: AgentRequest
    tgt*: SharedPtr[Agent]

  SigilsThread* = ref object of Agent
    thread*: Thread[Chan[ThreadSignal]]
    inputs*: Chan[ThreadSignal]

  AgentProxyShared* = ref object of Agent
    remote*: SharedPtr[Agent]
    chan*: Chan[ThreadSignal]

  AgentProxyWeak* = ref object of Agent
    remote*: WeakRef[Agent]
    chan*: Chan[ThreadSignal]

  AgentProxy*[T] = ref object of AgentProxyShared

proc newSigilsThread*(): SigilsThread =
  result = SigilsThread()
  result.inputs = newChan[ThreadSignal]()

proc moveToThread*[T: Agent](agent: T, thread: SigilsThread): AgentProxy[T] =

  if not isUniqueRef(agent):
    raise newException(AccessViolationDefect,
            "agent must be unique and not shared to be passed to another thread!")
  
  return AgentProxy[T](
    remote: newSharedPtr(unsafeIsolate(Agent(agent))),
    chan: thread.inputs
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
    chan: ct.inputs,
    remote: newSharedPtr(unsafeIsolate Agent(b)),
  )
  a.remote[].addAgentListeners(signalName(signal), proxy, slot)

