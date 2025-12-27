import std/locks
import std/options
import ./protocol
import ./agents
import ./threads
import ./svariant

type AgentLocation* = object
  thread*: SigilThreadPtr
  agent*: WeakRef[AgentActor]
  typeId*: TypeId
  isProxy*: bool

var registry: Table[SigilName, AgentLocation]
var regLock: Lock
regLock.initLock()

type ProxyCacheKey = tuple[thread: SigilThreadPtr, agent: WeakRef[AgentActor]]

var proxyCache {.threadVar.}: Table[ProxyCacheKey, AgentProxyShared]

type SetupProxyParams = object
  proxy*: WeakRef[AgentProxyShared]

proc keepAlive(context: Agent, params: SigilParams) {.nimcall.} =
  raise newException(AssertionDefect, "this should never be called!")

proc registerGlobalNameImpl[T](
    name: SigilName, proxy: AgentProxy[T], override = false
) {.gcsafe.} =
  {.cast(gcsafe).}:
    if not override and name in registry:
      raise newException(ValueError, "Name already registered! Name: " & $name)
    registry[name] = AgentLocation(
      thread: proxy.remoteThread,
      agent: proxy.remote,
      typeId: getTypeId(T),
    )
    let sub = ThreadSub(src: proxy.remote.toKind(Agent),
                        name: sn"sigils:registryKeepAlive",
                        tgt: proxy.remote.toKind(Agent),
                        fn: keepAlive)
    proxy.remoteThread.send(ThreadSignal(kind: AddSub, add: sub))

proc registerGlobalName*[T](
    name: SigilName, proxy: AgentProxy[T], override = false
) {.gcsafe.} =
  withLock regLock:
    {.cast(gcsafe).}:
      registerGlobalNameImpl(name, proxy, override)

proc registerGlobalAgent*[T: AgentActor](
    name: SigilName, thread: SigilThreadPtr, agent: var T, override = false
) {.gcsafe.} =
  withLock regLock:
    {.cast(gcsafe).}:
      let proxy = agent.moveToThread(thread)
      registerGlobalNameImpl(name, proxy, override = override)

proc removeGlobalName*[T](name: SigilName, proxy: AgentProxy[
    T]): bool {.gcsafe.} =
  withLock regLock:
    {.cast(gcsafe).}:
      if name in registry:
        let loc = registry[name]
        let sub = ThreadSub(src: proxy.remote.toKind(Agent),
                            name: sn"sigils:registryKeepAlive",
                            tgt: proxy.remote.toKind(Agent),
                            fn: keepAlive)
        loc.thread.send(ThreadSignal(kind: DelSub, del: sub))
        return true
      return false

proc lookupGlobalName*(name: SigilName): Option[AgentLocation] {.gcsafe.} =
  withLock regLock:
    {.cast(gcsafe).}:
      if name in registry:
        result = some registry[name]

proc lookupAgentProxyImpl[T](name: SigilName, location: AgentLocation,
    tp: typeof[T], cache = true): AgentProxy[T] =
  if getTypeId(T) != location.typeId:
    raise newException(ValueError, "can't create proxy of the correct type!")
  if location.thread.isNil or location.agent.isNil:
    raise newException(KeyError, "could not find agent")

  let key: ProxyCacheKey = (location.thread, location.agent)
  if key in proxyCache:
    let cached = proxyCache[key]
    if not cached.isNil:
      echo "Registry:cached: ", name, " ref: ", $cached.unsafeWeakRef()
      return AgentProxy[T](cached)

  result.initProxy(location.agent, location.thread)

  if cache:
    echo "Registry:cache: ", $result.unsafeWeakRef()
    proxyCache[key] = AgentProxyShared(result)

proc lookupAgentProxy*[T](name: SigilName, tp: typeof[T]): AgentProxy[T] {.gcsafe.} =
  withLock regLock:
    {.cast(gcsafe).}:
      if name notin registry:
        raise newException(KeyError, "could not find agent proxy: " & $(name))
      else:
        return lookupAgentProxyImpl(name, registry[name], tp)
