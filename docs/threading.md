# Sigils Threading

Sigils uses message passing to keep agent state owned by one scheduler at a
time. A moved agent is not shared between threads. The original ref is moved
into the destination scheduler, and the caller keeps an `AgentProxy[T]` that
knows how to send work to the real agent.

That design gives the important safety rule:

> Agent methods run on the scheduler that owns the real agent. Other threads
> talk to that agent through messages and proxies.

This document focuses on the core mechanics: `AgentProxy`, `Move`, `Deref`,
per-agent inboxes, and the lifetime rules that keep cross-thread calls safe.

## The Main Pieces

- `AgentActor` is an agent with a mailbox (`inbox`) and a lock around its
  subscription lists.
- `SigilThread` is the scheduler base type. It owns moved agents in
  `references: Table[WeakRef[Agent], Agent]`.
- `SigilThreadDefault` is the normal one-worker scheduler. It receives
  `ThreadSignal`s on `inputs` and executes them serially in `runForever()`.
- `SigilThreadPool` is a cooperative worker pool. It is still a `SigilThread`,
  but it leases one actor at a time so one actor is never run by two workers at
  once.
- `AgentProxy[T]` is the local handle returned by `moveToThread`. It has:
  `remote`, `remoteThread`, `homeThread`, and a local subscription list.
- `ThreadSignal` is the scheduler message type. The important variants are
  `Move`, `Call`, `Trigger`, `Deref`, `AddSub`, `DelSub`, and `Exit`.

The thread-local current scheduler is available through
`getCurrentSigilThread()`. Worker threads set this automatically. A main thread
that receives callbacks from workers must poll its local scheduler with
`poll()` or `pollAll()`.

## Ownership Model

Moving an agent is a transfer of the strong ref. After `moveToThread`, caller
code should treat the original variable as gone and use only the returned proxy.

<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 920 330" role="img" aria-labelledby="move-title move-desc">
  <title id="move-title">Move transfers ownership and leaves a proxy behind</title>
  <desc id="move-desc">Before move, the source thread owns an agent. After Move, the destination scheduler owns the agent in references, and source code uses an AgentProxy.</desc>
  <defs>
    <marker id="arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="8" markerHeight="8" orient="auto-start-reverse">
      <path d="M 0 0 L 10 5 L 0 10 z" fill="#333"/>
    </marker>
    <style>
      .box { fill: #f8fafc; stroke: #334155; stroke-width: 2; rx: 10; }
      .agent { fill: #e0f2fe; stroke: #0369a1; stroke-width: 2; rx: 8; }
      .proxy { fill: #ecfccb; stroke: #4d7c0f; stroke-width: 2; rx: 8; }
      .store { fill: #fff7ed; stroke: #c2410c; stroke-width: 2; rx: 8; }
      .text { font: 15px sans-serif; fill: #111827; }
      .small { font: 13px sans-serif; fill: #374151; }
      .label { font: 700 16px sans-serif; fill: #111827; }
      .line { stroke: #333; stroke-width: 2; fill: none; marker-end: url(#arrow); }
      .dash { stroke: #64748b; stroke-width: 2; stroke-dasharray: 7 5; fill: none; marker-end: url(#arrow); }
    </style>
  </defs>

  <rect class="box" x="35" y="45" width="340" height="235"/>
  <text class="label" x="60" y="78">Source thread</text>
  <rect class="agent" x="83" y="115" width="190" height="55"/>
  <text class="text" x="111" y="149">Counter agent</text>
  <text class="small" x="83" y="205">Before move: source owns the ref</text>

  <rect class="box" x="545" y="45" width="340" height="235"/>
  <text class="label" x="570" y="78">Destination scheduler</text>
  <rect class="store" x="592" y="107" width="230" height="82"/>
  <text class="text" x="625" y="136">references table</text>
  <text class="small" x="620" y="164">WeakRef[Agent] -&gt; Agent</text>

  <path class="line" d="M 275 143 C 365 143 445 143 592 143"/>
  <text class="text" x="414" y="125">Move(agent)</text>

  <rect class="proxy" x="83" y="215" width="190" height="42"/>
  <text class="text" x="128" y="242">AgentProxy</text>
  <path class="dash" d="M 273 236 C 410 260 520 220 592 178"/>
  <text class="small" x="385" y="266">proxy.remote + proxy.remoteThread</text>
</svg>

The move is implemented by `moveToThread(agent, thread)`:

1. It requires the agent ref to be unique. If the ref is still shared,
   `moveToThread` raises instead of creating a cross-thread GC alias.
2. It creates an `AgentProxy[T]` on the current thread.
3. It rewrites subscriptions so local callers target the proxy and remote
   signals can be forwarded back to local listeners.
4. It sends `ThreadSignal(kind: Move, item: move agent)` to the destination.
5. The destination scheduler stores the moved strong ref in `references`.

The proxy keeps only weak identity for the real agent. The scheduler owns the
strong ref.

## How A Proxy Sends A Call

A proxy does not call the real agent directly. It packages the slot call as a
`ThreadSignal(Call)`, puts it in the target actor inbox, and asks the remote
scheduler to make that actor ready.

<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 980 390" role="img" aria-labelledby="call-title call-desc">
  <title id="call-title">Local proxy sends a call to a remote agent</title>
  <desc id="call-desc">A local signal reaches AgentProxy. The proxy enqueues a Call into the remote actor inbox and marks the actor ready. The owning scheduler executes the slot.</desc>
  <defs>
    <marker id="arrow-call" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="8" markerHeight="8" orient="auto-start-reverse">
      <path d="M 0 0 L 10 5 L 0 10 z" fill="#333"/>
    </marker>
    <style>
      .box { fill: #f8fafc; stroke: #334155; stroke-width: 2; rx: 10; }
      .node { fill: #e0f2fe; stroke: #0369a1; stroke-width: 2; rx: 8; }
      .proxy { fill: #ecfccb; stroke: #4d7c0f; stroke-width: 2; rx: 8; }
      .queue { fill: #fef9c3; stroke: #a16207; stroke-width: 2; rx: 8; }
      .run { fill: #fae8ff; stroke: #a21caf; stroke-width: 2; rx: 8; }
      .text { font: 14px sans-serif; fill: #111827; }
      .small { font: 12px sans-serif; fill: #374151; }
      .label { font: 700 16px sans-serif; fill: #111827; }
      .line { stroke: #333; stroke-width: 2; fill: none; marker-end: url(#arrow-call); }
    </style>
  </defs>

  <rect class="box" x="30" y="40" width="380" height="290"/>
  <text class="label" x="55" y="72">Home thread</text>
  <rect class="node" x="70" y="105" width="130" height="48"/>
  <text class="text" x="102" y="134">emit signal</text>
  <rect class="proxy" x="245" y="105" width="130" height="48"/>
  <text class="text" x="276" y="134">AgentProxy</text>
  <rect class="queue" x="148" y="218" width="170" height="58"/>
  <text class="text" x="178" y="243">Call message</text>
  <text class="small" x="174" y="262">slot + request + tgt</text>

  <rect class="box" x="560" y="40" width="380" height="290"/>
  <text class="label" x="585" y="72">Owning scheduler</text>
  <rect class="queue" x="605" y="105" width="155" height="58"/>
  <text class="text" x="643" y="130">actor inbox</text>
  <text class="small" x="642" y="149">Chan[ThreadSignal]</text>
  <rect class="run" x="790" y="105" width="115" height="58"/>
  <text class="text" x="816" y="139">markReady</text>
  <rect class="node" x="682" y="230" width="150" height="55"/>
  <text class="text" x="712" y="255">real agent</text>
  <text class="small" x="711" y="274">callMethod(slot)</text>

  <path class="line" d="M 200 129 L 245 129"/>
  <path class="line" d="M 310 153 L 250 218"/>
  <path class="line" d="M 318 247 C 420 247 505 134 605 134"/>
  <path class="line" d="M 760 134 L 790 134"/>
  <path class="line" d="M 848 163 C 845 215 815 230 782 230"/>
  <path class="line" d="M 682 243 C 590 230 570 170 605 151"/>

  <text class="small" x="420" y="225">enqueue isolated Call</text>
  <text class="small" x="782" y="202">scheduler leases actor</text>
</svg>

For `SigilThreadDefault`, `markReady` records the actor in `signaled` and
sends `Trigger`. When the scheduler receives `Trigger`, it drains each signaled
actor inbox and runs the calls serially.

For `SigilThreadPool`, `markReady` puts the actor identity in the pool ready
queue. A worker leases that actor, runs one call, releases the lease, and
requeues the actor if more inbox work is waiting. That is what allows many
actors to run in parallel while preserving single-actor serialization.

## Signals Back To The Home Thread

Remote-to-local delivery uses the same proxy in the opposite direction. When a
remote agent emits a signal that has local subscribers, the remote agent's
subscription points at the proxy with the sentinel `localSlot`. Calling that
proxy from the remote scheduler means "send this back to the proxy's home
thread."

<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 980 360" role="img" aria-labelledby="return-title return-desc">
  <title id="return-title">Remote signal returns through the proxy home thread</title>
  <desc id="return-desc">A remote agent emits a signal. The proxy detects that the current scheduler is not its home thread and queues the callback into the proxy inbox on the home scheduler.</desc>
  <defs>
    <marker id="arrow-return" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="8" markerHeight="8" orient="auto-start-reverse">
      <path d="M 0 0 L 10 5 L 0 10 z" fill="#333"/>
    </marker>
    <style>
      .box { fill: #f8fafc; stroke: #334155; stroke-width: 2; rx: 10; }
      .agent { fill: #e0f2fe; stroke: #0369a1; stroke-width: 2; rx: 8; }
      .proxy { fill: #ecfccb; stroke: #4d7c0f; stroke-width: 2; rx: 8; }
      .queue { fill: #fef9c3; stroke: #a16207; stroke-width: 2; rx: 8; }
      .text { font: 14px sans-serif; fill: #111827; }
      .small { font: 12px sans-serif; fill: #374151; }
      .label { font: 700 16px sans-serif; fill: #111827; }
      .line { stroke: #333; stroke-width: 2; fill: none; marker-end: url(#arrow-return); }
    </style>
  </defs>

  <rect class="box" x="40" y="50" width="365" height="245"/>
  <text class="label" x="65" y="82">Remote scheduler</text>
  <rect class="agent" x="90" y="118" width="145" height="55"/>
  <text class="text" x="124" y="150">real agent</text>
  <rect class="proxy" x="255" y="118" width="115" height="55"/>
  <text class="text" x="286" y="150">proxy</text>
  <text class="small" x="249" y="199">slot == localSlot</text>

  <rect class="box" x="575" y="50" width="365" height="245"/>
  <text class="label" x="600" y="82">Home thread</text>
  <rect class="queue" x="620" y="118" width="150" height="55"/>
  <text class="text" x="661" y="142">proxy inbox</text>
  <text class="small" x="646" y="160">queued callback</text>
  <rect class="agent" x="800" y="118" width="105" height="55"/>
  <text class="text" x="828" y="150">listener</text>
  <text class="small" x="625" y="226">main/event thread must poll</text>

  <path class="line" d="M 235 145 L 255 145"/>
  <path class="line" d="M 370 145 C 455 145 535 145 620 145"/>
  <path class="line" d="M 770 145 L 800 145"/>
  <text class="small" x="422" y="126">enqueue Call to homeThread</text>
</svg>

This is why local threads need a scheduler too. If the home thread is a UI or
main thread, call `getCurrentSigilThread().pollAll()` at appropriate points to
deliver callbacks.

## Lifetime And Cleanup

The scheduler's `references` table is the strong owner for moved agents. Cross
thread queues and proxies should carry weak identities and isolated request
payloads, not long-lived strong refs.

<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 960 390" role="img" aria-labelledby="life-title life-desc">
  <title id="life-title">Move and Deref lifetime flow</title>
  <desc id="life-desc">Move stores the strong ref in references. Deref asks the owning scheduler to remove a known reference or clean stale scheduler state. The pool defers release if the actor is currently running.</desc>
  <defs>
    <marker id="arrow-life" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="8" markerHeight="8" orient="auto-start-reverse">
      <path d="M 0 0 L 10 5 L 0 10 z" fill="#333"/>
    </marker>
    <style>
      .box { fill: #f8fafc; stroke: #334155; stroke-width: 2; rx: 10; }
      .node { fill: #e0f2fe; stroke: #0369a1; stroke-width: 2; rx: 8; }
      .proxy { fill: #ecfccb; stroke: #4d7c0f; stroke-width: 2; rx: 8; }
      .store { fill: #fff7ed; stroke: #c2410c; stroke-width: 2; rx: 8; }
      .warn { fill: #fee2e2; stroke: #b91c1c; stroke-width: 2; rx: 8; }
      .ok { fill: #dcfce7; stroke: #15803d; stroke-width: 2; rx: 8; }
      .text { font: 14px sans-serif; fill: #111827; }
      .small { font: 12px sans-serif; fill: #374151; }
      .label { font: 700 16px sans-serif; fill: #111827; }
      .line { stroke: #333; stroke-width: 2; fill: none; marker-end: url(#arrow-life); }
      .dash { stroke: #64748b; stroke-width: 2; stroke-dasharray: 7 5; fill: none; marker-end: url(#arrow-life); }
    </style>
  </defs>

  <rect class="box" x="35" y="45" width="355" height="285"/>
  <text class="label" x="60" y="78">Proxy side</text>
  <rect class="proxy" x="80" y="115" width="230" height="52"/>
  <text class="text" x="128" y="146">AgentProxy destroyed</text>
  <rect class="node" x="80" y="210" width="230" height="52"/>
  <text class="text" x="113" y="240">send Deref(identity)</text>

  <rect class="box" x="560" y="45" width="355" height="285"/>
  <text class="label" x="585" y="78">Owning scheduler</text>
  <rect class="store" x="605" y="104" width="245" height="60"/>
  <text class="text" x="654" y="130">references table</text>
  <text class="small" x="640" y="149">strong refs for moved agents</text>
  <rect class="warn" x="605" y="190" width="110" height="58"/>
  <text class="text" x="631" y="214">running?</text>
  <text class="small" x="623" y="232">pool only</text>
  <rect class="ok" x="740" y="190" width="110" height="58"/>
  <text class="text" x="764" y="214">release</text>
  <text class="small" x="756" y="232">when idle</text>

  <path class="line" d="M 195 167 L 195 210"/>
  <path class="line" d="M 310 236 C 425 236 500 134 605 134"/>
  <path class="line" d="M 728 164 L 660 190"/>
  <path class="line" d="M 715 219 L 740 219"/>
  <path class="dash" d="M 660 248 C 680 292 765 292 795 248"/>
  <text class="small" x="652" y="292">if running: mark closing, release after slot returns</text>
</svg>

`Deref` is a scheduler message, not a direct free from another thread. Its
meaning is:

- If the scheduler owns a strong ref for that identity, remove it from
  `references`.
- Clear stale readiness/signaled state for that identity.
- Run cleanup that prunes owned agents which no longer have connections.
- In `SigilThreadPool`, if the actor is currently leased by a worker, mark it
  `closing` and release the strong ref only after the slot returns.

That last point is important. A worker must never run a slot through a weak ref
after the scheduler has released the strong owner. The pool separates logical
close (`closing = true`) from physical release (`references.del(...)`) so
`Deref` cannot free a currently executing actor.

Global registration is another lifetime case. The registry installs a
keep-alive subscription with `AddSub` and removes it with `DelSub`. That keeps a
registered remote agent alive even if a local proxy is short-lived.

## Subscription Rewriting

`moveToThread` also rewrites existing connections so later signal delivery goes
through the proxy:

- If other agents listened to the moved agent, they now listen to the local
  proxy.
- If the moved agent listened to other local agents, those local agents now call
  the proxy, which forwards to the remote agent.
- When local code subscribes to a signal on the proxy, the proxy ensures the
  remote agent has a forwarding subscription back to the proxy using
  `localSlot`.

The proxy's local subscription list is therefore the stable API surface. Users
connect to the proxy; the proxy arranges the cross-thread forwarding details.

## Default Thread vs Thread Pool

Both schedulers implement the same `SigilThread` API, so `moveToThread` and
`AgentProxy` work with either one.

`SigilThreadDefault`:

- One OS thread owns all moved agents for that scheduler.
- `Trigger` drains every signaled actor inbox serially.
- It is simple and predictable: no two slots on that scheduler run at once.

`SigilThreadPool`:

- Several OS workers share one scheduler state and one ownership table.
- The ready queue contains actor identities, not individual calls.
- A worker leases one actor, executes one call, releases it, and requeues the
  actor if more work exists.
- The same actor is never leased by two workers at the same time.
- Different actors can run on different workers in parallel.

## Practical Example

```nim
import sigils
import sigils/threads

let worker = newSigilThread()
worker.start()

let home = getCurrentSigilThread()

var source = SomeAction.new()
var counter = Counter.new()
let counterProxy = counter.moveToThread(worker)

connectThreaded(source, valueChanged, counterProxy, setValue)
connectThreaded(counterProxy, updated, source, SomeAction.completed())

emit source.valueChanged(42)

# Required if this thread receives callbacks from the worker.
discard home.pollAll()

worker.setRunning(false)
worker.join()
```

After `moveToThread`, use `counterProxy` for all cross-thread connections. Do
not keep using the moved `counter` ref on the source thread.

## Safety Checklist

- Move only unique refs. `moveToThread` enforces this with `isUniqueRef`.
- Treat the returned `AgentProxy[T]` as the handle to the remote agent.
- Use `connectThreaded` for cross-thread signals and slots.
- Keep signal payloads thread-safe. Cross-thread `ThreadSignal`s are isolated
  with `isolateRuntime`.
- Poll the home scheduler when it needs to receive callbacks.
- Stop and join worker schedulers in tests and short-lived programs.
- Use the registry keep-alive helpers when a remote agent must outlive one local
  proxy.

## Things To Avoid

- Do not call methods on the moved agent ref after `moveToThread`.
- Do not store strong moved-agent refs in worker-local queues. Queue weak actor
  identities and let the scheduler's `references` table own the agent.
- Do not assume `Deref` is an immediate cross-thread destructor. It is a
  scheduler request and may be deferred until a running slot finishes.
- Do not forget to pump the home thread when expecting remote-to-local signals.

## Related Files

- `sigils/threadBase.nim`: scheduler base type, `ThreadSignal`, `Move`,
  `Deref`, `markReady`, polling, and default execution logic.
- `sigils/threadDefault.nim`: one-thread scheduler implementation.
- `sigils/threadPool.nim`: cooperative worker pool scheduler.
- `sigils/threadProxies.nim`: `AgentProxy`, `moveToThread`, and
  `connectThreaded`.
- `sigils/actors.nim`: `AgentActor` inbox and subscription locking.
- `tests/tslotsThread.nim` and `tests/tthreadPool.nim`: examples and coverage.
