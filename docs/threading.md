# Threading with Sigils

Use Sigils threading when you want an agent to do work in the background and
send results back to your application. Each moved agent belongs to a scheduler,
which runs its slots. Your application keeps a **proxy**: a local handle that
sends messages to that agent.

The basic flow is:

1. Create an `AgentActor` and a worker scheduler.
2. Move the actor to the worker with `moveToThread`.
3. Connect signals and slots through the returned `AgentProxy` using
   `connectThreaded`.
4. Process the local scheduler's queue to receive replies.

## A complete example

Here the application asks a background counter to change its value. The counter
sends the new value back, and the application waits until it receives that reply.
`setValue` runs on the worker; `record` runs on the main thread.

```nim
import sigils
import sigils/threads

type
  App = ref object of Agent
    received: bool
    value: int
  Counter = ref object of AgentActor
    value: int

proc changeRequested(self: App, value: int) {.signal.}
proc updated(self: Counter, value: int) {.signal.}

proc setValue(self: Counter, value: int) {.slot.} =
  self.value = value
  emit self.updated(value)

proc record(self: App, value: int) {.slot.} =
  self.value = value
  self.received = true

startLocalThreadDefault()
let home = getCurrentSigilThread()
let worker = newSigilThread()
worker.start()

try:
  # This scope releases the proxy before we stop the worker.
  block:
    let app = App()
    var counter = Counter()
    let proxy = counter.moveToThread(worker)

    connectThreaded(app, changeRequested, proxy, setValue)
    connectThreaded(proxy, updated, app, App.record())

    emit app.changeRequested(42)

    # Wait for the reply, running local callbacks as they arrive.
    while not app.received:
      discard home.poll()
    doAssert app.value == 42
finally:
  worker.setRunning(false)
  worker.join()
```

Save this as `threading_example.nim` in an Atlas project with Sigils installed,
then compile and run it with `nim c -r --mm:arc --threads:on threading_example.nim`.
ORC is supported too.

Sending a signal queues work; it does not wait for the remote slot to finish.
The loop above waits for an application-level reply before checking the result
and stopping the worker. If your worker might fail to reply, use a timeout or an
error signal in your application's wait logic.

## Moving an actor transfers ownership

An `AgentActor` is an agent that can be moved to a worker. After
`counter.moveToThread(worker)`, use the returned proxy to talk to the counter.
The worker now owns the counter's state; reading or calling the original actor
from another thread would bypass the message queue.

The actor must have a unique strong reference when it is moved. For example,
keeping another `let saved = counter` reference prevents the move. Sigils checks
this and raises `AccessViolationDefect` if the actor itself is shared. Shared
refs inside the actor can also prevent transfer and raise `IsolationError`.
Existing signal connections are redirected through the proxy during the move.

The proxy belongs to the scheduler where it was created, its **home scheduler**.
Connect to it there. To obtain a handle on another scheduler, use the registry
helpers rather than sharing the same proxy ref across threads.

Message arguments also need safe ownership. Prefer values such as numbers,
strings, and value objects. Do not use a message to share a mutable agent or an
ordinary `ref` between threads. Heap payloads must be independently owned or
explicitly transferred using the isolation helpers; isolation is checked when a
message crosses the thread boundary.

## Receiving replies: `poll` and `pollAll`

A worker runs its own message loop after `start()`. Your main thread usually has
other work to do, so its local scheduler needs to be serviced by your code.
`startLocalThreadDefault()` installs that scheduler without starting another OS
thread.

For the default local scheduler:

| Call | What it does | When to use it |
| --- | --- | --- |
| `home.poll()` | Waits for a message, then processes it. | A command-line program waiting for a result. |
| `home.pollAll()` | Processes queued messages until the queue is empty, then returns. | An application loop that also handles other work. |

**One call to `pollAll()` does not wait for a future reply.** It can return before
the worker has even started your request. Check an application-level completion
condition, as in the example, instead of assuming that an empty local queue means
the worker has finished.

In a GUI, call `pollAll()` from the application thread when the event loop wakes.
The [Siwin example](../README.md#siwin-application-loop) shows how to wake the
application when a Sigils message arrives. Avoid a tight loop that repeatedly
calls `pollAll()` while idle; use a blocking wait or an event-loop wakeup.

## Choosing a scheduler

Start with `newSigilThread()` unless you need parallel actors or integration with
an existing event loop.

| Scheduler | How it runs work |
| --- | --- |
| `newSigilThread()` | One worker thread processes calls in order. All actors on that scheduler share the worker. |
| `newSigilThreadPool(workers = 4)` | Several workers can run different actors in parallel. Each actor runs at most one queued call at a time. |
| `newSigilSelectorThread()` | Integrates messages with selector events and timers. Import `sigils/threadSelectors`. |
| `AsyncSigilThread` | Integrates with `asyncdispatch`. Import `sigils/threadAsyncs`. |
| `newSigilChronosThread()` | Integrates with Chronos and sleeps in its dispatcher while idle. Import `sigils/threadChronos`. |

A pool does not make one actor's slots run in parallel. Split independent work
among several actors to use multiple workers. An actor can run on a different
worker for its next call, so store actor state in its fields, rather than in
thread-local variables. A proxy created inside a pool actor routes its callbacks
through that actor's queue, preserving the actor's serialization.

Keep slots short enough for other queued work to make progress. A slot that waits
synchronously for a reply needing the same actor or worker can deadlock. Send a
request, return from the slot, and handle the response in another slot.

## Queue growth and overload

Ordinary sends enqueue messages without waiting for spare queue capacity. The
queue grows when needed. This avoids a request/reply deadlock where the caller
is stuck sending requests while the worker is stuck sending replies.

This also means **queue capacity is not a memory limit for ordinary sends**. If a
producer continually runs faster than its consumer, queued work and memory use
will grow. Limit outstanding requests, send work in batches after acknowledgments,
or coalesce repeated updates when only the latest value matters.

For code that sends `ThreadSignal` messages directly, the `NonBlocking` send
option applies the mailbox's admission limit and raises `MessageQueueFullError`
when it is full. The internal mailbox's `trySend` returns `false` instead. Normal
`connectThreaded` emissions use ordinary sends; they do not opt into this limit.
Neither mode waits for the receiving slot to finish, and both synchronize queue
access with a lock.

## Lifetime and shutdown

Keep a proxy alive for as long as you need its remote actor. Even a proxy used
only to send requests keeps the actor alive. Dropping one proxy does not
invalidate other handles to the same actor.

Once the last proxy is gone, the scheduler can collect the actor if it has no
remaining connections. Global registration can keep an actor available without
a local proxy; removing one name leaves other names for that actor intact. See
[`registry.nim`](../sigils/registry.nim) for registration and lookup helpers.

Queued calls do not keep their receiver alive. If a local receiver or proxy is
destroyed before a queued call runs, that delivery is discarded. This applies to
`connectQueued` as well as cross-thread delivery. Keep receivers alive until you
have received the results you care about.

For an orderly shutdown:

1. Stop producing new requests.
2. Receive any results your application needs. Stopping a scheduler is not a
   guarantee that all outstanding requests and replies have completed.
3. Release proxies while their schedulers are still available.
4. Request worker shutdown, then join it. Use `worker.setRunning(false)` for the
   default scheduler, or `pool.stop()` for a thread pool, followed by `join()`.

A proxy does not own its scheduler. The scheduler must remain valid while any
proxy or producer can still send to it. `join()` waits for worker termination; it
does not process replies waiting on the home scheduler.

## When something appears stuck

- **The worker runs, but the reply never arrives:** check that the proxy's home
  scheduler is being polled and that the local receiver is still alive.
- **A result is missing immediately after `pollAll()`:** the reply may not have
  arrived yet. Wait for a completion signal or condition.
- **Other work stops while one slot runs:** that slot may be blocking the worker.
  In a pool, calls to the same actor still wait for the current call to return.
- **Memory grows under load:** limit the amount of outstanding work. Ordinary
  sends allow the queue to grow.
- **Moving an actor raises an isolation error:** check for extra strong refs to
  the actor or to mutable objects stored inside it.

## How delivery works internally

This section is useful when extending a scheduler or investigating a bug. Normal
application code can use the proxies and connection helpers above.

The destination scheduler holds the moved actor's strong reference. Queued calls
and subscription snapshots carry a shared **delivery endpoint**: a small record
with an actor identity, liveness state, and routing information. They do not hold
ordinary ARC/ORC references to an actor on another thread. Dispatch checks the
endpoint before delivering a call. Once closed, that endpoint stays closed even
if a new object later occupies the same memory address.

Default and event-loop schedulers place calls and control messages in their
input FIFO. The pool puts calls in the appropriate actor's inbox and gives a
worker exclusive access to that actor for one call. Proxy callbacks from pool
actors use the same mechanism. Under ORC, cycle candidates are cleared before
moving an actor or handing it to another pool worker.

The main scheduler messages are:

| Message | Purpose |
| --- | --- |
| `Move` | Transfer an actor into scheduler ownership. |
| `Call` | Deliver a slot call if its receiver is still alive. |
| `Release` | Recheck collection after a proxy releases its remote handle. |
| `Deref` | Explicitly close an actor, even if handles remain. A pool waits for an active call to return before freeing it. |
| `AddSub` / `DelSub` | Update connections, including registry keepalive connections. |
| `Trigger` | Process actors marked ready through the lower-level actor-inbox hooks. Unfinished readiness is restored if a slot raises. |
| `Exit` | Request scheduler shutdown. |

The implementation lives in [`threadBase.nim`](../sigils/threadBase.nim),
[`threadProxies.nim`](../sigils/threadProxies.nim),
[`threadPool.nim`](../sigils/threadPool.nim), and
[`mailboxes.nim`](../sigils/mailboxes.nim). For more executable examples, see
[`tslotsThread.nim`](../tests/tslotsThread.nim) and
[`tthreadPool.nim`](../tests/tthreadPool.nim). The failure cases are covered in
[`tthreadSafety.nim`](../tests/tthreadSafety.nim).
