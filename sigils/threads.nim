import std/sets
import agents

type
  AgentProxy*[T] = ref object of Agent
    
proc moveToThead*[T: Agent](agent: T): AgentProxy[T] {.raises: [AccessViolationDefect].} =

  if not isUniqueRef(agent):
    raise newException(AccessViolationDefect, "agent must be unique and not shared to be passed to another thread!")

  
