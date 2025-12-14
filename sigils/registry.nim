import std/locks
import std/options
import ./protocol
import ./agents
import ./threads
import ./svariant

type AgentLocation* = object
  thread*: SigilThreadPtr
  agent*: WeakRef[Agent]
  typeId*: TypeId

var registry: Table[SigilName, AgentLocation]
var regLock: Lock

proc registerGlobalName*[T](name: SigilName, proxy: AgentProxy[T], override = false) =
  withLock regLock:
    if not override and name in registry:
      raise newException(ValueError, "Name already registered! Name: " & $name)
    registry[name] = AgentLocation(
      thread: proxy.remoteThread,
      agent: proxy.remote,
      typeId: getTypeId(T),
    )

proc removeGlobalName*[T](name: SigilName, proxy: AgentProxy[T]): bool =
  withLock regLock:
    if name in registry:
      registry.del(name)

proc lookupGlobalName*(name: SigilName): Option[AgentLocation] =
  withLock regLock:
    if name in registry:
      result = some registry[name]

proc toAgentProxy*[T](location: AgentLocation, tp: typeof[T]): AgentProxy[T] =
  if getTypeId(T) != location.typeId:
    raise newException(ValueError, "can't create proxy of the correct type!")
  discard


