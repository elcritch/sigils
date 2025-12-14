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
var keepAlive: Table[SigilName, AgentProxyShared]
var regLock: Lock
regLock.initLock()

type ProxyCacheKey = tuple[thread: SigilThreadPtr, agent: WeakRef[Agent]]

var proxyCache {.threadVar.}: Table[ProxyCacheKey, AgentProxyShared]

type SetupProxyParams = object
  proxy*: WeakRef[AgentProxyShared]

proc setupRemoteProxy(context: Agent, params: SigilParams) {.nimcall.} =
  var setup: SetupProxyParams
  rpcUnpack(setup, params)
  if setup.proxy.isNil:
    return

  let remoteProxy = setup.proxy[]
  remoteProxy.addSubscription(AnySigilName, context, localSlot)
  context.addSubscription(AnySigilName, remoteProxy, remoteSlot)

proc registerGlobalName*[T](name: SigilName, proxy: AgentProxy[T],
    override = false) =
  withLock regLock:
    if not override and name in registry:
      raise newException(ValueError, "Name already registered! Name: " & $name)
    registry[name] = AgentLocation(
      thread: proxy.remoteThread,
      agent: proxy.remote,
      typeId: getTypeId(T),
    )
    keepAlive[name] = AgentProxyShared(proxy)

proc removeGlobalName*[T](name: SigilName, proxy: AgentProxy[T]): bool =
  withLock regLock:
    if name in registry:
      registry.del(name)
      if name in keepAlive:
        keepAlive.del(name)
      return true
    return false

proc lookupGlobalName*(name: SigilName): Option[AgentLocation] =
  withLock regLock:
    if name in registry:
      result = some registry[name]

proc toAgentProxy*[T](location: AgentLocation, tp: typeof[T]): AgentProxy[T] =
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

  result = AgentProxy[T](
    remote: location.agent,
    remoteThread: location.thread,
    inbox: newChan[ThreadSignal](1_000),
  )

  var remoteProxy = AgentProxy[T](
    remote: location.agent,
    remoteThread: ct,
    inbox: newChan[ThreadSignal](1_000),
  )

  result.lock.initLock()
  remoteProxy.lock.initLock()

  result.proxyTwin = remoteProxy.unsafeWeakRef().toKind(AgentProxyShared)
  remoteProxy.proxyTwin = result.unsafeWeakRef().toKind(AgentProxyShared)

  when defined(sigilsDebug):
    let aid = $location.agent
    result.debugName = "localProxy::" & aid
    remoteProxy.debugName = "remoteProxy::" & aid

  # Ensure the remote proxy is kept alive until it is wired on the remote thread.
  remoteProxy.addSubscription(AnySigilName, result, localSlot)

  let remoteProxyRef = remoteProxy.unsafeWeakRef().toKind(AgentProxyShared)
  location.thread.send(ThreadSignal(kind: Move, item: move remoteProxy))

  let setupReq = SigilRequest(
    kind: Request,
    origin: SigilId(-1),
    procName: sn"setupRemoteProxy",
    params: SigilParams(buf: newWrapperVariant(SetupProxyParams(
        proxy: remoteProxyRef))),
  )
  location.thread.send(
    ThreadSignal(kind: Call, slot: setupRemoteProxy, req: setupReq,
        tgt: location.agent)
  )

  proxyCache[key] = AgentProxyShared(result)
