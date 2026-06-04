import std/[cpuinfo, deques, locks, tables]
import threading/atomics

import isolateutils
import agents
import actors
import core
import hybridTables
import threadBase

export threadBase

type
  PoolActorState = object
    running: bool
    queued: bool
    closing: bool

  SigilThreadPool* = object of SigilThread
    workers*: seq[Thread[SigilThreadPoolPtr]]
    workerCount*: int
    inboxSize*: int
    queueLock*: Lock
    queueCond*: Cond
    ready*: Deque[WeakRef[AgentActor]]
    states*: Table[WeakRef[AgentActor], PoolActorState]
    stopping*: bool

  SigilThreadPoolPtr* = ptr SigilThreadPool

proc actorRef(actor: WeakRef[AgentActor]): WeakRef[Agent] =
  actor.toKind(Agent)

proc actorRef(sig: ThreadSignal): WeakRef[AgentActor] =
  sig.tgt.toKind(AgentActor)

proc hasReference(pool: SigilThreadPoolPtr, actor: WeakRef[AgentActor]): bool =
  actor.actorRef in pool[].references

proc removeActor(pool: SigilThreadPoolPtr, actor: WeakRef[AgentActor]) =
  pool[].states.del(actor)
  pool[].references.del(actor.actorRef)
  withLock pool[].signaledLock:
    pool[].signaled.excl(actor)

proc delSelfSubscription(actor: WeakRef[AgentActor], sub: ThreadSub) =
  withLock actor[].lock:
    let removed = actor[].subcriptions.removeValuesForKey(sub.name) do(
        subscription: Subscription
    ) -> HybridRemoveAction:
      if subscription.tgt != sub.tgt:
        hraKeep
      elif sub.fn == nil or subscription.packedSlot == sub.fn:
        hraDelete
      else:
        hraFound
    if removed.found == removed.deleted:
      actor[].listening.excl(actor.actorRef)

proc enqueueReadyLocked(pool: SigilThreadPoolPtr, actor: WeakRef[AgentActor]) =
  if actor notin pool[].states:
    return
  var state = pool[].states[actor]
  if state.closing:
    return
  if state.running:
    state.queued = true
  elif not state.queued:
    state.queued = true
    pool[].ready.addLast(actor)
    pool[].queueCond.signal()
  pool[].states[actor] = state

method markReady*(
    pool: SigilThreadPoolPtr, actor: WeakRef[AgentActor]
) {.gcsafe.} =
  withLock pool[].queueLock:
    pool.enqueueReadyLocked(actor)

proc popReady(pool: SigilThreadPoolPtr): WeakRef[AgentActor] =
  withLock pool[].queueLock:
    while pool[].ready.len == 0 and not pool[].stopping:
      pool[].queueCond.wait(pool[].queueLock)
    if pool[].ready.len > 0:
      result = pool[].ready.popFirst()

proc leaseActor(
    pool: SigilThreadPoolPtr, actor: WeakRef[AgentActor]
): bool =
  if actor.isNil:
    return false
  withLock pool[].queueLock:
    if actor notin pool[].states:
      return false
    if not pool.hasReference(actor):
      pool[].states.del(actor)
      return false
    var state = pool[].states[actor]
    if state.closing or state.running:
      return false
    state.running = true
    state.queued = false
    pool[].states[actor] = state
    result = true

proc releaseActor(pool: SigilThreadPoolPtr, actor: WeakRef[AgentActor]) =
  withLock pool[].queueLock:
    if actor notin pool[].states:
      return
    var state = pool[].states[actor]
    state.running = false
    if state.closing:
      pool.removeActor(actor)
    else:
      let hasInboxWork = actor[].inbox.peek() > 0
      if hasInboxWork or state.queued:
        state.queued = true
        pool[].ready.addLast(actor)
        pool[].queueCond.signal()
      pool[].states[actor] = state

proc handleException(pool: SigilThreadPoolPtr, e: ref Exception) {.gcsafe.} =
  if pool[].exceptionHandler.isNil:
    raise e
  else:
    pool[].exceptionHandler(e)

proc runActorSignal(
    pool: SigilThreadPoolPtr, actor: WeakRef[AgentActor]
) {.gcsafe.} =
  var sig: ThreadSignal
  if actor[].inbox.tryRecv(sig):
    try:
      pool.exec(sig)
    except CatchableError as e:
      pool.handleException(e)
    except Defect as e:
      pool.handleException(e)
    except Exception as e:
      pool.handleException(e)

proc runPoolWorker(pool: SigilThreadPoolPtr) {.thread.} =
  {.cast(gcsafe).}:
    doAssert not hasLocalSigilThread()
    setLocalSigilThread(pool)
    while pool.isRunning():
      let actor = pool.popReady()
      if actor.isNil:
        discard
      elif pool.leaseActor(actor):
        try:
          pool.runActorSignal(actor)
        finally:
          pool.releaseActor(actor)

proc newSigilThreadPool*(
    workers = countProcessors(), inbox = 1_000
): SigilThreadPoolPtr =
  let workerCount =
    if workers < 1: 1
    else: workers
  result = cast[SigilThreadPoolPtr](allocShared0(sizeof(SigilThreadPool)))
  result[] = SigilThreadPool(
    workerCount: workerCount,
    inboxSize: inbox,
    ready: initDeque[WeakRef[AgentActor]](),
    states: initTable[WeakRef[AgentActor], PoolActorState](),
  )
  result[].agent = SigilThreadAgent()
  result[].workers = newSeq[Thread[SigilThreadPoolPtr]](workerCount)
  result[].signaledLock.initLock()
  result[].queueLock.initLock()
  result[].queueCond.initCond()
  result[].threadId.store(-1, Relaxed)
  result[].running.store(true, Relaxed)

method send*(
    pool: SigilThreadPoolPtr, msg: sink ThreadSignal,
        blocking: BlockingKinds
) {.gcsafe.} =
  var sig = msg
  case sig.kind
  of Move:
    if not (sig.item of AgentActor):
      raise newException(ValueError, "thread pool can only move AgentActor instances")
    var item = sig.item
    let actor = item.unsafeWeakRef().toKind(AgentActor)
    AgentActor(item).ensureActorReady(pool[].inboxSize)
    withLock pool[].queueLock:
      pool[].references[actor.actorRef] = move item
      if actor notin pool[].states:
        pool[].states[actor] = PoolActorState()
  of Call:
    if sig.tgt.isNil or not (sig.tgt[] of AgentActor):
      raise newException(ValueError, "thread pool direct Call requires an AgentActor target")
    let actor = sig.actorRef()
    actor[].ensureActorReady(pool[].inboxSize)
    var callSig = isolateRuntime(sig)
    actor[].inbox.send(callSig)
    pool.markReady(actor)
  of AddSub:
    if sig.add.src.isNil:
      raise newException(UnableToSubscribe, "unable to subscribe nil src: " &
                                            $sig.add.src & " to " & $sig.add.tgt)
    var canSubscribe = false
    withLock pool[].queueLock:
      canSubscribe = sig.add.src in pool[].references and
          sig.add.tgt in pool[].references
    if canSubscribe:
      sig.add.src[].addSubscription(sig.add.name, sig.add.tgt[], sig.add.fn)
    else:
      raise newException(UnableToSubscribe, "unable to subscribe to missing" &
                                            " src: " & $sig.add.src &
                                            " to " & $sig.add.tgt)
  of DelSub:
    if sig.del.src.isNil:
      raise newException(UnableToSubscribe, "unable to unsubscribe nil del: " &
                                            $sig.del.src & " to " & $sig.del.tgt)
    var canSubscribe = false
    withLock pool[].queueLock:
      canSubscribe = sig.del.src in pool[].references and
          sig.del.tgt in pool[].references
    if canSubscribe:
      if sig.del.src == sig.del.tgt and sig.del.src[] of AgentActor:
        sig.del.src.toKind(AgentActor).delSelfSubscription(sig.del)
      else:
        sig.del.src[].delSubscription(sig.del.name, sig.del.tgt, sig.del.fn)
    else:
      raise newException(UnableToSubscribe, "unable to subscribe to missing" &
                                            " src: " & $sig.del.src &
                                            " to " & $sig.del.tgt)
  of Deref:
    let actor = sig.deref.toKind(AgentActor)
    withLock pool[].queueLock:
      if actor in pool[].states:
        var state = pool[].states[actor]
        if state.running:
          state.closing = true
          state.queued = false
          pool[].states[actor] = state
        else:
          pool.removeActor(actor)
  of Trigger:
    discard
  of Exit:
    withLock pool[].queueLock:
      pool[].stopping = true
      pool[].running.store(false, Relaxed)
      pool[].queueCond.broadcast()

method recv*(
    pool: SigilThreadPoolPtr, msg: var ThreadSignal,
        blocking: BlockingKinds
): bool {.gcsafe.} =
  raise newException(AssertionDefect, "thread pool does not expose recv")

method setTimer*(
    pool: SigilThreadPoolPtr, timer: SigilTimer
) {.gcsafe.} =
  raise newException(AssertionDefect, "not implemented for thread pool")

method poll*(
    pool: SigilThreadPoolPtr, blocking: BlockingKinds = Blocking
): bool {.gcsafe, discardable.} =
  raise newException(AssertionDefect, "thread pool does not support poll")

proc start*(pool: SigilThreadPoolPtr) =
  if pool[].exceptionHandler.isNil:
    pool[].exceptionHandler = defaultExceptionHandler
  for idx in 0 ..< pool[].workerCount:
    createThread(pool[].workers[idx], runPoolWorker, pool)

proc stop*(pool: SigilThreadPoolPtr, immediate = false) =
  if immediate:
    withLock pool[].queueLock:
      pool[].stopping = true
      pool[].running.store(false, Relaxed)
      pool[].queueCond.broadcast()
  else:
    pool.send(ThreadSignal(kind: Exit))

proc join*(pool: SigilThreadPoolPtr) =
  doAssert not pool.isNil
  for idx in 0 ..< pool[].workerCount:
    pool[].workers[idx].joinThread()

proc peek*(pool: SigilThreadPoolPtr): int =
  withLock pool[].queueLock:
    result = pool[].ready.len
