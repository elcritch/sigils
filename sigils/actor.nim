import std/locks
import threading/channels

import agents
import core

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

  AgentActor* = ref object of Agent
    inbox*: SigilChan
    lock*: Lock

method removeSubscriptionsFor*(
    self: AgentActor, subscriber: WeakRef[Agent]
) {.gcsafe, raises: [].} =
  withLock self.lock:
    procCall removeSubscriptionsFor(Agent(self), subscriber)

method unregisterSubscriber*(
    self: AgentActor, listener: WeakRef[Agent]
) {.gcsafe, raises: [].} =
  withLock self.lock:
    procCall unregisterSubscriber(Agent(self), listener)

method hasSubscription*(
    obj: AgentActor, sig: SigilName
): bool {.gcsafe, raises: [].} =
  withLock obj.lock:
    result = hasSubscriptionImpl(Agent(obj), sig)

method hasSubscription*(
    obj: AgentActor, sig: SigilName, tgt: Agent | WeakRef[Agent]
): bool {.gcsafe, raises: [].} =
  let tgtRef = tgt.unsafeWeakRef().toKind(Agent)
  withLock obj.lock:
    result = hasSubscriptionImpl(Agent(obj), sig, tgtRef)

method hasSubscription*(
    obj: AgentActor, sig: SigilName, tgt: Agent | WeakRef[Agent],
        slot: AgentProc
): bool {.gcsafe, raises: [].} =
  let tgtRef = tgt.unsafeWeakRef().toKind(Agent)
  withLock obj.lock:
    result = hasSubscriptionImpl(Agent(obj), sig, tgtRef, slot)

method addSubscription*(
    obj: AgentActor, sig: SigilName, tgt: Agent | WeakRef[Agent],
        slot: AgentProc
) {.gcsafe, raises: [].} =
  let tgtRef = tgt.unsafeWeakRef().toKind(Agent)
  withLock obj.lock:
    addSubscriptionImpl(Agent(obj), sig, tgtRef, slot)

method delSubscription*(
    self: AgentActor, sig: SigilName, tgt: Agent | WeakRef[Agent],
        slot: AgentProc
) {.gcsafe, raises: [].} =
  let tgtRef = tgt.unsafeWeakRef().toKind(Agent)
  withLock self.lock:
    delSubscriptionImpl(Agent(self), sig, tgtRef, slot)

method callSlots*(obj: AgentActor, req: SigilRequest) {.gcsafe.} =
  var subs: seq[Subscription]
  withLock obj.lock:
    for sub in obj.getSubscriptions(req.procName):
      subs.add(sub)
  callSlotsImpl(Agent(obj), req, subs.items)

