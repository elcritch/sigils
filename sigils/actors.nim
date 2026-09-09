import std/locks
import threading/channels
import mailboxes

import agents
export mailboxes

type
  ThreadSignalKind* {.pure.} = enum
    Call
    Move
    AddSub
    DelSub
    Trigger
    Deref
    Release
    Exit

  ThreadSignal* = object
    case kind*: ThreadSignalKind
    of Call:
      slot*: AgentProc
      req*: SigilRequest
      tgt*: WeakRef[Agent]
      endpoint*: AgentEndpoint
    of Move:
      item*: Agent
    of AddSub:
      add*: ThreadSub
    of DelSub:
      del*: ThreadSub
    of Trigger:
      discard
    of Deref, Release:
      deref*: WeakRef[Agent]
    of Exit:
      discard

  ThreadSub* = object
    src*: WeakRef[Agent]
    name*: SigilName
    tgt*: WeakRef[Agent]
    fn*: AgentProc

  SigilChan* = Mailbox[ThreadSignal]

proc newSigilChan*(capacity = 1_000): SigilChan =
  newMailbox[ThreadSignal](capacity)

proc prepareDelivery*(msg: var ThreadSignal) =
  if msg.kind == Call and msg.endpoint.isNil and not msg.tgt.isNil:
    msg.endpoint = msg.tgt[].endpoint()

type
  AgentActor* = ref object of Agent
    inbox*: SigilChan
    lock*: Lock
    ready*: bool

proc `=destroy`*(actor: var typeof(AgentActor()[])) =
  `=destroy`(toAgentObj(cast[AgentActor](addr actor)))
  `=destroy`(actor.inbox)
  if actor.ready:
    deinitLock(actor.lock)

proc ensureActorReady*(self: AgentActor, inbox = 1_000) =
  ## Lazily initialize AgentActor synchronization/storage.
  if not self.ready:
    discard self.endpoint()
    self.inbox = newSigilChan(inbox)
    self.lock.initLock()
    self.ready = true

method hasConnections*(self: AgentActor): bool {.gcsafe, raises: [].} =
  self.ensureActorReady()
  withLock self.lock:
    result = procCall hasConnections(Agent(self))

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

method hasSubscription*(
    obj: AgentActor, sig: SigilName, subscription: Subscription
): bool {.gcsafe, raises: [].} =
  obj.ensureActorReady()
  withLock obj.lock:
    result = procCall hasSubscription(Agent(obj), sig, subscription)

method addListener*(obj: AgentActor, tgt: WeakRef[Agent]) {.gcsafe, raises: [].} =
  obj.ensureActorReady()
  withLock obj.lock:
    obj.listening.incl(tgt)

method delListener*(obj: AgentActor, tgt: WeakRef[Agent]) {.gcsafe, raises: [].} =
  obj.ensureActorReady()
  withLock obj.lock:
    obj.listening.excl(tgt)

method addSubscription*(
    obj: AgentActor, sig: SigilName, subscription: Subscription
) {.gcsafe, raises: [].} =
  obj.ensureActorReady()
  doAssert not obj.isNil(), "agent is nil!"
  when sigilsSlotEnvDisabled:
    assert subscription.packedSlot != nil or subscription.directSlot != nil
  else:
    assert subscription.packedSlot != nil or subscription.directSlot != nil or
      subscription.envSlot != nil

  var added = false
  let subscription = subscription.prepareSubscription()
  withLock obj.lock:
    if addSubscriptionSorted(obj.subcriptions, sig, subscription):
      added = true

  if added:
    subscription.tgt[].addListener(obj.unsafeWeakRef().asAgent())

method addSubscription*(
    obj: AgentActor, sig: SigilName, tgt: WeakRef[Agent], slot: AgentProc
) {.gcsafe, raises: [].} =
  addSubscription(obj, sig, Subscription(tgt: tgt, packedSlot: slot))

method addSubscription*(
    obj: AgentActor,
    sig: SigilName,
    tgt: WeakRef[Agent],
    slot: AgentProc,
    directSlot: LocalAgentProc
) {.gcsafe, raises: [].} =
  addSubscription(obj, sig, Subscription(tgt: tgt, packedSlot: slot,
      directSlot: directSlot))

method delSubscription*(
    self: AgentActor, sig: SigilName, tgt: WeakRef[Agent], slot: AgentProc
) {.gcsafe, raises: [].} =
  self.ensureActorReady()

  var removed = false
  var stillListening = false
  withLock self.lock:
    for idx in countdown(self.subcriptions.high, 0):
      let item = self.subcriptions[idx]
      if item.signal == sig and item.subscription.tgt == tgt and
          (slot.isNil or item.subscription.packedSlot == slot):
        item.subscription.invalidateConnectionState()
        self.subcriptions.delete(idx)
        removed = true
    for item in self.subcriptions:
      if item.subscription.tgt == tgt:
        stillListening = true
  if removed and not stillListening:
    tgt[].delListener(self.unsafeWeakRef().asAgent())

method delSubscription*(
    self: AgentActor, sig: SigilName, subscription: Subscription
) {.gcsafe, raises: [].} =
  self.ensureActorReady()
  var removed = false
  var stillListening = false
  withLock self.lock:
    for idx in countdown(self.subcriptions.high, 0):
      let item = self.subcriptions[idx]
      if item.signal == sig and item.subscription.sameSubscription(subscription):
        item.subscription.invalidateConnectionState()
        self.subcriptions.delete(idx)
        removed = true
    for item in self.subcriptions:
      if item.subscription.tgt == subscription.tgt:
        stillListening = true
  if removed and not stillListening:
    subscription.tgt[].delListener(self.unsafeWeakRef().asAgent())
