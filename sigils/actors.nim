import std/locks
import threading/channels

import agents

type
  ThreadSignalKind* {.pure.} = enum
    Call
    Move
    AddSub
    DelSub
    Trigger
    Deref
    Exit

  ThreadSignal* = object
    case kind*: ThreadSignalKind
    of Call:
      slot*: AgentProc
      req*: SigilRequest
      tgt*: WeakRef[Agent]
    of Move:
      item*: Agent
    of AddSub:
      add*: ThreadSub
    of DelSub:
      del*: ThreadSub
    of Trigger:
      discard
    of Deref:
      deref*: WeakRef[Agent]
    of Exit:
      discard

  ThreadSub* = object
    src*: WeakRef[Agent]
    name*: SigilName
    tgt*: WeakRef[Agent]
    fn*: AgentProc

  SigilChan* = Chan[ThreadSignal]

type
  AgentActor* = ref object of Agent
    inbox*: SigilChan
    lock*: Lock
    ready*: bool

proc ensureActorReady*(self: AgentActor, inbox = 1_000) =
  ## Lazily initialize AgentActor synchronization/storage.
  if not self.ready:
    self.inbox = newChan[ThreadSignal](inbox)
    self.lock.initLock()
    self.ready = true

method removeSubscriptionsFor*(
    self: AgentActor, subscriber: WeakRef[Agent]
) {.gcsafe, raises: [].} =
  self.ensureActorReady()
  withLock self.lock:
    procCall removeSubscriptionsFor(Agent(self), subscriber)

method unregisterSubscriber*(
    self: AgentActor, listener: WeakRef[Agent]
) {.gcsafe, raises: [].} =
  self.ensureActorReady()
  withLock self.lock:
    procCall unregisterSubscriber(Agent(self), listener)

method hasSubscription*(
    obj: AgentActor, sig: SigilName
): bool {.gcsafe, raises: [].} =
  obj.ensureActorReady()
  withLock obj.lock:
    result = procCall hasSubscription(Agent(obj), sig)

method hasSubscription*(
    obj: AgentActor, sig: SigilName, tgt: WeakRef[Agent]): bool {.gcsafe,
        raises: [].} =
  obj.ensureActorReady()
  withLock obj.lock:
    result = procCall hasSubscription(Agent(obj), sig, tgt)

method hasSubscription*(
    obj: AgentActor, sig: SigilName, tgt: WeakRef[Agent], slot: AgentProc
): bool {.gcsafe, raises: [].} =
  obj.ensureActorReady()
  withLock obj.lock:
    result = procCall hasSubscription(Agent(obj), sig, tgt, slot)

method addListener*(obj: AgentActor, tgt: WeakRef[Agent]) {.gcsafe, raises: [].} =
  withLock obj.lock:
    obj.listening.incl(tgt)

method delListener*(obj: AgentActor, tgt: WeakRef[Agent]) {.gcsafe, raises: [].} =
  withLock obj.lock:
    obj.listening.excl(tgt)

method addSubscription*(
    obj: AgentActor, sig: SigilName, tgt: WeakRef[Agent], slot: AgentProc
) {.gcsafe, raises: [].} =
  obj.ensureActorReady()
  doAssert not obj.isNil(), "agent is nil!"
  assert slot != nil

  var added = false
  withLock obj.lock:
    if not procCall hasSubscription(Agent(obj), sig, tgt, slot):
      obj.subcriptions.add((sig, Subscription(tgt: tgt, slot: slot)))
      added = true

  if added:
    tgt[].addListener(obj.unsafeWeakRef().asAgent())

method delSubscription*(
    self: AgentActor, sig: SigilName, tgt: WeakRef[Agent], slot: AgentProc
) {.gcsafe, raises: [].} =
  self.ensureActorReady()
  var
    subsFound: int
    subsDeleted: int

  withLock self.lock:
    procCall delSubscription(Agent(self), sig, tgt, slot)

