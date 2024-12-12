import std/sets
import std/isolation
import agents
import threading/smartptrs
import threading/channels

export channels, smartptrs

type
  AgentProxy*[T] = ref object of Agent
    remote*: SharedPtr[T]

  AgentSignal* = object
    obj: WeakRef[Agent]
    req: AgentRequest

  AgentThread* = ref object of Agent
    thread*: Thread[void]
    inputs*: Chan[AgentRequest]

proc newAgentThread*(): AgentThread =
  result = AgentThread()

proc moveToThread*[T: Agent](agent: T, thread: AgentThread): AgentProxy[T] =

  if not isUniqueRef(agent):
    raise newException(AccessViolationDefect,
            "agent must be unique and not shared to be passed to another thread!")
  
  return AgentProxy[T](remote: newSharedPtr(unsafeIsolate(agent)))

template connect*[T](
    a: Agent,
    signal: typed,
    b: AgentProxy[T],
    slot: typed,
    acceptVoidSlot: static bool = false,
): void =
  ## connects `AgentProxy[T]` to remote signals
  ## 
  let agentSlot = `slot`(typeof(b.remote[]))
  checkSignalTypes(a, signal, b.remote[], agentSlot, acceptVoidSlot)
  # a.addAgentListeners(signalName(signal), b, agentSlot)

template connect*[T, S](
    a: Agent,
    signal: typed,
    b: AgentProxy[T],
    slot: Signal[S],
    acceptVoidSlot: static bool = false,
): void =
  ## connects `AgentProxy[T]` to remote signals
  ## 
  checkSignalTypes(a, signal, b.remote[], slot, acceptVoidSlot)
  # a.addAgentListeners(signalName(signal), b, slot)

