# Cooperative Thread Pool Plan

## Goal

Add a cooperative scheduler that lets multiple actors run across a worker pool while preserving the core Sigils actor rule: a single actor must never execute on more than one thread at the same time. An actor may run on worker A for one signal and later run on worker B for a later signal.

The pool should be introduced as a new scheduler type, not as a replacement for `SigilThreadDefault`. Existing `moveToThread`, `AgentProxy`, and `connectThreaded` usage should continue to work when the destination is the pool.

## Current Design Notes

The current threading model is centered on `SigilThread` implementations:

- `SigilThreadDefault` owns moved agents in `references`.
- `AgentProxyShared` points at one `remoteThread` and one weak remote actor.
- Cross-thread proxy calls enqueue a `ThreadSignal(Call)` into the remote actor inbox, mark the actor in `remoteThread.signaled`, and send `Trigger`.
- `Trigger` drains all signaled actor inboxes serially on the owning thread.
- `Move` transfers a strong `Agent` ref into `references`.
- `Deref` removes that strong ref and clears signaled state.

That design gives exclusive execution because each `SigilThread` has one OS worker. A pool needs the same exclusivity at actor granularity instead of scheduler granularity.

## New Scheduler Type

Add a new module, likely `sigils/threadPool.nim`, exported from `sigils/threads.nim`.

Public API:

```nim
type
  SigilThreadPool* = object of SigilThread

  SigilThreadPoolPtr* = ptr SigilThreadPool

proc newSigilThreadPool*(workers = countProcessors(), inbox = 1_000): SigilThreadPoolPtr
proc start*(pool: SigilThreadPoolPtr)
proc stop*(pool: SigilThreadPoolPtr, immediate = false)
proc join*(pool: SigilThreadPoolPtr)
proc peek*(pool: SigilThreadPoolPtr): int
```

`SigilThreadPool` remains a `SigilThread`, so existing APIs that accept `SigilThreadPtr` can route to it through dynamic dispatch.

Use `std/locks` and `std/deques`. The repo's Nim version does not provide `std/locking`, so do not import it.

## Internal State

The pool owns all moved actors as a scheduler, not per worker.

```nim
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
```

The inherited `references` table remains the pool-wide strong owner table:

- key: `WeakRef[Agent]`
- value: moved `Agent`

Workers should only carry weak refs while executing. They must not create long-lived strong refs outside the pool table.

## Scheduling Contract

The ready queue contains actor identities, not individual calls.

When a sender queues work:

1. It sends an isolated `ThreadSignal(Call)` into the target actor inbox.
2. It marks that actor ready in the pool.
3. The pool wakes one worker.

When a worker runs:

1. Pop one actor weak ref from `ready`.
2. Under `queueLock`, validate the actor still has state, is not closing, and is not already running.
3. Mark `running = true` and `queued = false`.
4. Receive exactly one `ThreadSignal` from that actor inbox with `tryRecv`.
5. Execute that one call outside `queueLock`.
6. Reacquire `queueLock`, mark `running = false`.
7. If the actor is closing, release it from `references` and remove its state.
8. Otherwise, if more inbox work is available or `queued` was set while running, push the actor back to `ready`.

This one-call lease is the fairness rule. It avoids one busy actor monopolizing a worker and gives later signals a chance to run on another worker.

## Actor Readiness

Add an overridable readiness hook to the scheduler layer so proxy code does not hardcode the current `signaled`/`Trigger` pattern.

Suggested base method in `threadBase.nim`:

```nim
method markReady*(thread: SigilThreadPtr, actor: WeakRef[AgentActor]) {.base, gcsafe.} =
  thread.signal(actor)
  thread.send(ThreadSignal(kind: Trigger))
```

Then update proxy routing to call:

```nim
proxy.remoteThread.markReady(proxy.remote)
proxy.homeThread.markReady(proxy.unsafeWeakRef().toKind(AgentActor))
```

`SigilThreadDefault` can use the base behavior. `SigilThreadPool` overrides `markReady` to enqueue into its ready deque and signal the condition variable. In the pool, `Trigger` becomes a no-op compatibility message.

## Pool `send` Semantics

`send` should still isolate incoming `ThreadSignal`s before sharing them with worker threads.

`Move`:

- Require that `sig.item` is an `AgentActor`.
- Call `ensureActorReady(inboxSize)`.
- Store the moved strong ref in inherited `references`.
- Create `states[actorWeak]` if missing.

`Call`:

- Require that `sig.tgt` is an `AgentActor`.
- Enqueue the call into the actor inbox.
- Mark the actor ready.
- Direct `Call` to non-actor targets is unsupported for v1 and should raise a clear exception.

`AddSub` and `DelSub`:

- Apply using the same checks as `threadBase.exec`.
- These operations mutate actor subscription lists, which are already protected by `AgentActor.lock`.
- They must not execute while holding `queueLock`.

`Deref`:

- If the actor is not known, ignore it.
- If the actor is running, mark `closing = true`.
- If the actor is idle, remove state and delete the strong ref from `references`.
- Also remove any stale ready entries lazily by validating on pop; do not scan the deque.

`Trigger`:

- No-op for the pool.

`Exit`:

- Set `stopping = true`.
- Store inherited `running = false`.
- Broadcast the condition variable to wake all workers.

## Worker Thread Setup

Each worker thread should set its local scheduler to the pool pointer:

```nim
setLocalSigilThread(pool)
```

This preserves `getCurrentSigilThread()` behavior inside slots. The inherited `threadId` cannot represent all workers; for a pool it may store `-1` or the creator thread id. Tests that need actual worker identity should use Nim's `getThreadId()` directly from inside slots.

Exceptions from slots should follow the existing `runForever` behavior:

- If `exceptionHandler` is nil, re-raise.
- Otherwise pass the exception to `exceptionHandler`.
- Always release the actor lease in a `finally`-style path after an exception.

## Lifetime and Deref Safety

The critical lifetime rule is that `Deref` cannot remove the pool's strong reference while a worker is executing a slot on that actor.

Use `running` and `closing` to separate logical deletion from physical release:

- `Deref` while idle releases immediately.
- `Deref` while running marks `closing`.
- The worker releases after the slot returns and before any requeue.

Do not attempt to copy strong `Agent` refs into worker-local queues. Queue only weak refs and validate against `states` and `references` before execution.

Stale queue entries are acceptable. A worker that pops an actor with no state, no reference, `closing`, or `running = true` discards that entry and waits for another.

## Backpressure

For v1, keep the existing per-actor `Chan[ThreadSignal]` inbox and its configured capacity. The pool-level ready queue is unbounded `Deque[WeakRef[AgentActor]]`, but each actor should only have one queued ready entry unless it is currently running and receives more work.

Readiness rules:

- If idle and not queued, push actor to `ready` and set `queued = true`.
- If running, set `queued = true` but do not push a second entry.
- If already queued, do nothing.

This bounds ready queue growth to roughly the number of live actors plus stale entries.

## Tests

Add tests under `tests/`, likely `tthreadPool.nim`.

Required scenarios:

- Single actor serialization: enqueue many signals to one actor; inside the slot increment an atomic `inSlot`, assert it is never greater than `1`, then decrement.
- Multiple actor parallelism: move two or more actors to the same pool, block their slots briefly, and assert at least two distinct worker thread ids are observed.
- Actor mobility: send many sequential signals to one actor under competing load and record worker ids; assert calls remain serialized and more than one worker can execute that actor over time.
- Proxy round trip: local actor emits to pooled actor, pooled actor emits back to local proxy, and the local thread receives it after `pollAll()`.
- Deref while busy: destroy or drop the proxy while the remote actor is executing; verify no use-after-free, no crash, and no later calls run after close.
- Registry keep-alive: register a pooled actor globally, then remove it, covering `AddSub` and `DelSub`.

Run:

```sh
nim test
nim c -r tests/tthreadPool.nim
```

When touching scheduling or lifetime code, also run the focused test with `-d:tsan` if the local toolchain supports it.

## Implementation Order

1. Add `markReady` to `threadBase.nim` with current default behavior.
2. Update `threadProxies.nim` to use `markReady`.
3. Add `threadPool.nim` with pool types, constructor, lifecycle, `send`, and worker loop.
4. Export `threadPool` from `sigils/threads.nim`.
5. Add focused tests.
6. Run tests and fix any ARC/ORC ownership issues found by compilation or runtime assertions.

## Explicit v1 Non-goals

- No work stealing between per-worker queues; the pool has one shared ready deque.
- No batching beyond one signal per actor lease.
- No timer or selector integration in the pool.
- No replacement of `SigilThreadDefault`.
- No support for non-`AgentActor` targets in pooled direct `Call` messages.
