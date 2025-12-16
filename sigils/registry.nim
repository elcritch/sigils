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
  isProxy*: bool

var registry: Table[SigilName, AgentLocation]
var regLock: Lock
regLock.initLock()

type ProxyCacheKey = tuple[thread: SigilThreadPtr, agent: WeakRef[Agent]]

var proxyCache {.threadVar.}: Table[ProxyCacheKey, AgentProxyShared]

type SetupProxyParams = object
  proxy*: WeakRef[AgentProxyShared]

proc keepAlive(context: Agent, params: SigilParams) {.nimcall.} =
  raise newException(AssertionDefect, "this should never be called!")

proc initProxy[T](proxy: var AgentProxy[T],
                  agent: WeakRef[Agent],
                  thread: SigilThreadPtr,
                  isRemote = false, inbox = 1_000) =
  proxy = AgentProxy[T](
    remote: agent,
    remoteThread: thread,
    inbox: newChan[ThreadSignal](inbox),
  )
  proxy.lock.initLock()
  when defined(sigilsDebug):
    let aid = $agent
    if remote:
      proxy.debugName = "remoteProxy::" & aid
    else:
      proxy.debugName = "localProxy::" & aid

proc bindProxies[T](a, b: AgentProxy[T]) =
  a.proxyTwin = b.unsafeWeakRef().toKind(AgentProxyShared)
  b.proxyTwin = a.unsafeWeakRef().toKind(AgentProxyShared)

proc registerGlobalAgent*[T](
    name: SigilName, agent: T, override = false
) {.gcsafe.} =
  withLock regLock:
    {.cast(gcsafe).}:
      if not override and name in registry:
        raise newException(ValueError, "Name already registered! Name: " & $name)

      let remoteProxyRef = remoteProxy.unsafeWeakRef().toKind(AgentProxyShared)
      location.thread.send(ThreadSignal(kind: Move, item: move remoteProxy))
      let sub = ThreadSub(src: location.agent,
                          name: AnySigilName,
                          tgt: remoteProxyRef.toKind(Agent),
                          fn: remoteSlot)
      location.thread.send(ThreadSignal(kind: AddSub, add: sub))

      registry[name] = AgentLocation(
        thread: proxy.remoteThread,
        agent: proxy.remote,
        typeId: getTypeId(T),
        isProxy: true
      )

      let sub = ThreadSub(src: proxy.remote,
                          name: sn"sigils:registryKeepAliveProxy",
                          tgt: proxy.remote,
                          fn: keepAlive)
      proxy.remoteThread.send(ThreadSignal(kind: AddSub, add: sub))

proc registerGlobalName*[T](
    name: SigilName, proxy: AgentProxy[T], override = false
) {.gcsafe.} =
  withLock regLock:
    {.cast(gcsafe).}:
      if not override and name in registry:
        raise newException(ValueError, "Name already registered! Name: " & $name)
      registry[name] = AgentLocation(
        thread: proxy.remoteThread,
        agent: proxy.remote,
        typeId: getTypeId(T),
      )
      let sub = ThreadSub(src: proxy.remote,
                          name: sn"sigils:registryKeepAlive",
                          tgt: proxy.remote,
                          fn: keepAlive)
      proxy.remoteThread.send(ThreadSignal(kind: AddSub, add: sub))

proc removeGlobalName*[T](name: SigilName, proxy: AgentProxy[T]): bool {.gcsafe.} =
  withLock regLock:
    {.cast(gcsafe).}:
      if name in registry:
        let loc = registry[name]
        let sub = ThreadSub(src: proxy.remote,
                            name: sn"sigils:registryKeepAlive",
                            tgt: proxy.remote,
                            fn: keepAlive)
        loc.thread.send(ThreadSignal(kind: DelSub, del: sub))
        return true
      return false

proc lookupGlobalName*(name: SigilName): Option[AgentLocation] {.gcsafe.} =
  withLock regLock:
    {.cast(gcsafe).}:
      if name in registry:
        result = some registry[name]

proc lookupAgentProxyImpl[T](location: AgentLocation, tp: typeof[T], cache = true): AgentProxy[T] =
  if getTypeId(T) != location.typeId:
    raise newException(ValueError, "can't create proxy of the correct type!")
  if location.thread.isNil or location.agent.isNil:
    return nil

  let key: ProxyCacheKey = (location.thread, location.agent)
  if key in proxyCache:
    let cached = proxyCache[key]
    if not cached.isNil:
      return cast[AgentProxy[T]](cached)

  let ct = getCurrentSigilThread()
  var remoteProxy: AgentProxy[T]

  result.initProxy(location.agent, location.thread, isRemote = false)
  remoteProxy.initProxy(location.agent, ct, isRemote = true)
  bindProxies(result, remoteProxy)

  # Ensure the remote proxy is kept alive until it is wired on the remote thread.
  remoteProxy.addSubscription(AnySigilName, result, localSlot)

  let remoteProxyRef = remoteProxy.unsafeWeakRef().toKind(AgentProxyShared)
  location.thread.send(ThreadSignal(kind: Move, item: move remoteProxy))
  let sub = ThreadSub(src: location.agent,
                      name: AnySigilName,
                      tgt: remoteProxyRef.toKind(Agent),
                      fn: remoteSlot)
  location.thread.send(ThreadSignal(kind: AddSub, add: sub))

  if cache:
    proxyCache[key] = AgentProxyShared(result)

proc lookupAgentProxy*[T](name: SigilName, tp: typeof[T]): AgentProxy[T] {.gcsafe.} =
  withLock regLock:
    {.cast(gcsafe).}:
      if name notin registry:
        return nil
      else:
        return lookupAgentProxyImpl(registry[name], tp)

