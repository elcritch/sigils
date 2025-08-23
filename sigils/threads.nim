import std/sets
import std/isolation
import std/options
import std/locks
import threading/smartptrs
import threading/channels

import isolateutils
import agents
import core
import threadBase
import threadProxies

export isolateutils
export threadBase
export threadProxies

# Queued connection helper: route a signal to a target slot by
# enqueueing a `Call` on a specific `SigilThread`'s inputs channel.

type
  QueuedDispatch* = ref object of Agent
    remoteThread*: ptr SigilThread
    tgt*: WeakRef[Agent]
    slotPtr*: AgentProc

proc queuedEnqueueSlot*(context: Agent, params: SigilParams) {.nimcall, gcsafe.} =
  ## Generic slot implementation used by `connectQueued`.
  ## Wraps incoming `params` into a `ThreadSignal.Call` and enqueues it
  ## to the destination thread for later execution on `tgt`.
  let self = QueuedDispatch(context)
  if self.isNil: raise newException(ConversionError, "bad queued dispatch")

  # Build a minimal SigilRequest carrying params. procName/id are unused
  # for direct-slot `Call` execution, but kept for completeness.
  var req: SigilRequest
  req.kind = Request
  req.origin = SigilId(-1)
  req.procName = AnySigilName
  req.params = params

  var req2 = req.deepCopy()
  let msg = ThreadSignal(kind: Call, slot: self.slotPtr, req: move req2, tgt: self.tgt)
  self.remoteThread[].send(msg)

template connectQueued*[T](
    a: Agent,
    signal: typed,
    thread: ptr SigilThread,
    b: Agent,
    slot: Signal[T],
    acceptVoidSlot: static bool = false,
): QueuedDispatch =
  ## Connect `a.signal` to `b.slot` by queueing a Call on `thread`.
  ## Returns the internal dispatcher agent so callers can manage its lifetime if needed.
  checkSignalTypes(a, signal, b, slot, acceptVoidSlot)
  let dispatcher = QueuedDispatch(
    remoteThread: thread,
    tgt: b.unsafeWeakRef().asAgent(),
    slotPtr: slot,
  )
  a.addSubscription(signalName(signal), dispatcher, queuedEnqueueSlot)
  dispatcher

template connectQueued*(
    a: Agent,
    signal: typed,
    thread: ptr SigilThread,
    b: Agent,
    slot: untyped,
    acceptVoidSlot: static bool = false,
): QueuedDispatch =
  ## Overload that accepts an untyped `slot` name (e.g., `Counter.setValue`).
  let agentSlot = `slot`(typeof(b))
  connectQueued(a, signal, thread, b, agentSlot, acceptVoidSlot)

template connectQueued*[T](
    a: Agent,
    signal: typed,
    b: Agent,
    slot: Signal[T],
    acceptVoidSlot: static bool = false,
): QueuedDispatch =
  ## Overload that queues onto the current (local) thread.
  let ct = getCurrentSigilThread()
  connectQueued(a, signal, ct, b, slot, acceptVoidSlot)

template connectQueued*(
    a: Agent,
    signal: typed,
    b: Agent,
    slot: untyped,
    acceptVoidSlot: static bool = false,
): QueuedDispatch =
  ## Overload that queues onto the current (local) thread with untyped slot.
  let agentSlot = `slot`(typeof(b))
  connectQueued(a, signal, b, agentSlot, acceptVoidSlot)
