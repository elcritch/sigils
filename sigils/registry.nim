import std/locks
import ./protocol
import ./agents
import ./threads

type AgentLocation* = object
  thread*: SigilThreadPtr
  agent*: WeakRef[Agent]

var registry: Table[SigilName, AgentLocation]
var regLock: Lock

proc registerGlobalName*[T](name: SigilName, proxy: AgentProxy[T], override = false) =
  withLock regLock:
    if not override and name in registry:
      raise newException(ValueError, "Name already registered! Name: " & $name)
    registry[name] = AgentLocation(thread: proxy.remoteThread, agent: proxy.remote)

proc removeGlobalName*[T](name: SigilName, proxy: AgentProxy[T]): bool =
  withLock regLock:
    if name in registry:
      registry.del(name)

proc lookupGlobalName*(name: SigilName): AgentLocation =
  withLock regLock:
    if name in registry:
      result = registry[name]

