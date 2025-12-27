# Sigils

A [signal and slots library](https://en.wikipedia.org/wiki/Signals_and_slots) implemented for the Nim programming language. The signals and slots are type checked and implemented purely in Nim. It can be used for event based programming both with GUIs or standalone.

> Signals and slots is a language construct introduced in Qt for communication between objects which makes it easy to implement the observer pattern while avoiding boilerplate code. The concept is that GUI widgets, and other objects, can send signals containing event information which can be received by other objects using special member functions known as slots. This is similar to C/C++ function pointers, but the signal/slot system ensures the type-correctness of callback arguments.
> - Wikipedia

Note that this implementation shares many or most of the limitations you'd see in Qt's implementation. Sigils also includes a message-passing threading model; see `docs/threading.md` for the detailed architecture and safety notes.

## Basics

Only objects inheriting from `Agent` can receive signals. Slots must take an `Agent` object as the first argument. The rest of the arguments must match that of the `signal` you wish to connect a slot to.

For threaded usage, prefer `AgentActor` (it extends `Agent` with a mailbox and lock for thread-safe subscription updates). `AgentActor` is required by `moveToThread` and by the proxy-based cross-thread APIs.

You need to wrap procs with a `slot` to set up the proc to support receiving signals. The proc can still be used as a normal function though. Signals use the proc syntax but don't have a implementation. They just provide the type checking and naming for the signal.

Connecting signals and slots is accomplished using `connect`. Note that `connect` is idempotent, meaning that you can call it on the same objects the multiple times without ill effect.

## Examples

```nim
import sigils

type
  Counter*[T] = ref object of Agent
    value: T

proc valueChanged*[T](tp: Counter[T], val: T) {.signal.}

proc setValue*[T](self: Counter[T], value: T) {.slot.} =
  echo "setValue! ", value
  if self.value != value:
    # we want to be careful not to set circular triggers
    self.value = value
    emit self.valueChanged(value)

var
  a = Counter[uint]()
  b = Counter[uint]()
  c = Counter[uint]()

connect(a, valueChanged,
        b, setValue)
connect(a, valueChanged,
        c, setValue)

doAssert b.value == 0
doAssert c.value == 0
emit a.valueChanged(137)

doAssert a.value == 0
doAssert b.value == 137
doAssert c.value == 137
```

## Alternative Connect for Slots

Sometimes the Nim compiler can't determine the which slot you want to use just by the types passed into the `connect` template. Other times you may want to specify a parent type's slot. 

The `{.slot.}` pragma generates some helper procs for these scenarios to allow you to ensure the specific slot passed to `connect`. These helpers procs take the type of their agent (the target) as the first argument. It looks like this:

```nim
let b = Counter[uint]()
connect(a, valueChanged,
        b, Counter[uint].setValue)

a.setValue(42) # we can directly call `setValue` which will then call emit

doAssert a.value == 42
doAssert b.value == 42
```

The `{.signal.}` pragma generates these provide several helper procs to make it easy to get the type of the signal argument. The `SignalTypes` types is used as the first argument to differentiate from normal invocation of signals. Here are some examples: 

```nim
test "signal / slot types":
  doAssert SignalTypes.avgChanged(Counter[uint]) is (float, )
  doAssert SignalTypes.valueChanged(Counter[uint]) is (uint, )
  doAssert SignalTypes.setValue(Counter[uint]) is (uint, )
```

## Threads

Sigils uses a message-passing model: agents are owned by one thread at a time, and cross-thread work is delivered via per-thread schedulers. To move an agent to another thread, it must be an `AgentActor` and you must use `moveToThread`, which returns an `AgentProxy[T]`. Use `connectThreaded(...)` for cross-thread wiring (since v0.18.0, `connect` does not accept proxies). If you expect inbound forwarded events on the local thread, you must `poll()`/`pollAll()` that thread's scheduler.

`moveToThread` transfers ownership; the agent must be unique (`isUniqueRef`) and the original reference should not be used after the move. Cross-thread signal params must be thread-safe (no shared `ref` fields); use `Isolate[T]` when you need to transfer heap payloads.

Thread implementations:
- `newSigilThread()` / `SigilThreadDefault`: blocking worker thread (message loop).
- `newSigilSelectorThread()` / `SigilSelectorThread`: selector-backed thread with timers and fd events.
- `AsyncSigilThread` (import `sigils/threadAsyncs`): integrates with `asyncdispatch`.

```nim
import sigils
import sigils/threads

type
  Counter = ref object of AgentActor
    value: int
  Sink = ref object of AgentActor
    seen: int

proc valueChanged(self: Counter, value: int) {.signal.}

proc setValue(self: Counter, value: int) {.slot.} =
  self.value = value
  emit self.valueChanged(value)

proc record(self: Sink, value: int) {.slot.} =
  self.seen = value

var
  src = Counter()
  dst = Counter()
  sink = Sink()

let worker = newSigilThread()
worker.start()
startLocalThreadDefault()

let proxy: AgentProxy[Counter] = dst.moveToThread(worker)

connectThreaded(src, valueChanged, proxy, setValue)  # local -> remote
connectThreaded(proxy, valueChanged, sink, record)   # remote -> local

emit src.valueChanged(42)

let ct = getCurrentSigilThread()
discard ct.pollAll() # deliver forwarded events to local thread

doAssert sink.seen == 42
```

## Closures

```nim
type
  Counter* = ref object of Agent

test "callback creation":
  var
    a = Counter()
    b = Counter(value: 100)

  let
    clsAgent =
      connectTo(a, valueChanged) do (val: int):
        b.value = val
  
  emit a.valueChanged(42)
  check b.value == 42 # callback modifies base
                      # beware capturing values like this
                      # it causes headaches, but can be handy
  check clsAgent.typeof() is ClosureAgent[(int,)]
```


## Advanced

Signal names aren't `string` types for performance considerations. Instead they're arrays with a maximum name size of 48 bytes currently. This can be changed if needed.

### Overriding Destructors

Overriding the `=destroy` destructors will result in bad things if you don't properly call the Agent destructor. See the following code for how to do this. Note that calling `=destroy` directly with casts doesn't seem to work.

```nim
type CounterWithDestroy* = ref object of Agent

proc `=destroy`*(x: var typeof(CounterWithDestroy()[])) =
  echo "CounterWithDestroy:destroy: ", x.debugName
  destroyAgent(x)
```

### Void Slots

There's an exception to the type checking. It's common in UI programming to want to trigger a `slot` without caring about the actual values in the signal. To achieve this you can call `connect` like this:

```nim
proc valueChanged*(tp: Counter, val: int) {.signal.}

proc someAction*(self: Counter) {.slot.} =
  echo "action"

connect(a, valueChanged, c, someAction, acceptVoidSlot = true)
emit a.valueChange(42)
```

Now whenever `valueChanged` is emitted then `someAction` will be triggered.

### WeakRefs

Calling `connect` _does not_ create a new reference of either the target or source agents. This is done primarily to prevent cycles from being created accidentally. This is necessary for easing UI development with _Sigil_.

However, `Agent` objects are still memory safe to use. They have a destructor which removes an `Agent` from any of it's "listeners" connections to ensure freed agents aren't signaled after they're freed. Nifty!

Note however, that means you need to ensure your `Agent`'s aren't destroyed before you're done with them. This applies to threaded signals using `AgentProxy[T]` as well.

### Serialization

Internally `sigils` was based on an RPC system. There are many similarities when calling typed compiled functions in a generic fashion.

To wit `sigils` supports multiple serialization methods. The default uses [variant](https://github.com/yglukhov/variant). In theory we could use the `any` type. Additionally JSON and CBOR methods are also supported by passing `-d:sigilsCborSerde` or `-d:sigilsJsonSerde`. These can be useful for backeneds such as NimScript and JavaScript. Using CBOR can be handy for networking which might be added in the future.


### Multiple Threads

This example sends one signal to two different agents living on two different threads, then collects both results back on the main thread.

```nim
import sigils, sigils/threads

type
  Trigger = ref object of AgentActor
  Worker = ref object of AgentActor
    value: int
  Collector = ref object of AgentActor
    a: int
    b: int

proc valueChanged(tp: Trigger, val: int) {.signal.}
proc updated(tp: Worker, final: int) {.signal.}

proc setValue(self: Worker, value: int) {.slot.} =
  self.value = value
  echo "worker:setValue: ", value, " (th: ", getThreadId(), ")"
  emit self.updated(self.value)

proc gotA(self: Collector, final: int) {.slot.} =
  echo "collector: gotA: ", final, " (th: ", getThreadId(), ")"
  self.a = final

proc gotB(self: Collector, final: int) {.slot.} =
  echo "collector: gotB: ", final, " (th: ", getThreadId(), ")"
  self.b = final

let trigger = Trigger()
let collector = Collector()

let threadA = newSigilThread()
let threadB = newSigilThread()
threadA.start()
threadB.start()
startLocalThreadDefault()

var wA = Worker()
var wB = Worker()

let workerA: AgentProxy[Worker] = wA.moveToThread(threadA)
let workerB: AgentProxy[Worker] = wB.moveToThread(threadB)

connectThreaded(trigger, valueChanged, workerA, setValue)
connectThreaded(trigger, valueChanged, workerB, setValue)
connectThreaded(workerA, updated, collector, Collector.gotA())
connectThreaded(workerB, updated, collector, Collector.gotB())

emit trigger.valueChanged(42)

let ct = getCurrentSigilThread()
discard ct.poll() # workerA result
discard ct.poll() # workerB result
doAssert collector.a == 42
doAssert collector.b == 42

setRunning(threadA, false)
setRunning(threadB, false)
threadA.join()
threadB.join()
```
