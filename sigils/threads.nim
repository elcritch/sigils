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

template connectRemote*[T](
    a: Agent,
    signal: typed,
    b: AgentProxy[T],
    slot: typed,
    acceptVoidSlot: static bool = false,
): void =
  ## sets up `b` to recieve events from `a`. Both `a` and `b`
  ## must subtype `Agent`. The `signal` must be a signal proc, 
  ## while `slot` must be a slot proc.
  ## 
  let rem: T = b.remote[]
  let agentSlot = `slot`(typeof(rem))
  checkSignalTypes(a, signal, b.remote[], agentSlot, acceptVoidSlot)
  a.addAgentListeners(signalName(signal), b, agentSlot)

