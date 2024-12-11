import std/sets
import agents
import threading/smartptrs
import threading/channels

export channels

type
  AgentProxy*[T] = ref object of Agent
    remote*: SharedPtr[T]

  AgentThread* = ref object of Agent

proc moveToThread*[T: Agent](agent: T): AgentProxy[T] =

  if not isUniqueRef(agent):
    raise newException(AccessViolationDefect,
            "agent must be unique and not shared to be passed to another thread!")

