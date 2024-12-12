import std/sets
import std/isolation
import agents
import threading/smartptrs
import threading/channels

export channels, smartptrs

type
  AgentProxy*[T] = ref object of Agent
    remote*: SharedPtr[T]

  AgentThread* = ref object of Agent

proc moveToThread*[T: Agent](agent: T): AgentProxy[T] =

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
  let rem: T = b.remote[]
  let agentSlot = `slot`(typeof(rem))
  checkSignalTypes(a, signal, b.remote[], agentSlot, acceptVoidSlot)
  a.addAgentListeners(signalName(signal), b, agentSlot)

template connect*[T, S](
    a: Agent,
    signal: typed,
    b: AgentProxy[T],
    slot: Signal[S],
    acceptVoidSlot: static bool = false,
): void =
  ## connects `AgentProxy[T]` to remote signals
  ## 
  let rem: T = b.remote[]
  checkSignalTypes(a, signal, b.remote[], slot, acceptVoidSlot)
  a.addAgentListeners(signalName(signal), b, slot)

