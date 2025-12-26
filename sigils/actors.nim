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
    result = procCall hasSubscription(Agent(obj), sig)

method hasSubscription*(
    obj: AgentActor, sig: SigilName, tgt: WeakRef[Agent]): bool {.gcsafe, raises: [].} =
  withLock obj.lock:
    result = procCall hasSubscription(Agent(obj), sig, tgt)

method hasSubscription*(
    obj: AgentActor, sig: SigilName, tgt: WeakRef[Agent], slot: AgentProc
): bool {.gcsafe, raises: [].} =
  withLock obj.lock:
    result = procCall hasSubscription(Agent(obj), sig, tgt, slot)

method addSubscription*(
    obj: AgentActor, sig: SigilName, tgt: WeakRef[Agent], slot: AgentProc
) {.gcsafe, raises: [].} =
  withLock obj.lock:
    procCall addSubscription(Agent(obj), sig, tgt, slot)

method delSubscription*(
    self: AgentActor, sig: SigilName, tgt: WeakRef[Agent], slot: AgentProc
) {.gcsafe, raises: [].} =
  withLock self.lock:
    procCall delSubscription(Agent(self), sig, tgt, slot)

