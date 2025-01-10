# Sigils

A [signal and slots library](https://en.wikipedia.org/wiki/Signals_and_slots) implemented for the Nim programming language. The signals and slots are type checked and implemented purely in Nim.

> Signals and slots is a language construct introduced in Qt for communication between objects which makes it easy to implement the observer pattern while avoiding boilerplate code. The concept is that GUI widgets, and other objects, can send signals containing event information which can be received by other objects using special member functions known as slots. This is similar to C/C++ function pointers, but the signal/slot system ensures the type-correctness of callback arguments.
> - Wikipedia

Note that this implementation shares many or most of the limitations you'd see in Qt's implementation. Sigils currently only has rudimentary multi-threading, but I hope to expand them over time.

## Basics

Only objects inheriting from `Agent` can recieve signals. Slots must take an `Agent` object as the first argument. The rest of the arguments must match that of the `signal` you wish to connect a slot to.

You need to wrap procs with a `slot` to setup the proc to support recieving signals. The proc can still be used as a normal function though. Signals use the proc syntax but don't have a implementation. They just provide the type checking and naming for the signal.

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
  a = Counter[uint].new()
  b = Counter[uint].new()
  c = Counter[uint].new()

connect(a, valueChanged,
        b, Counter[uint].setValue())
connect(a, valueChanged,
        c, Counter[uint].setValue())

doAssert b.value == 0
doAssert c.value == 0
emit a.valueChanged(137)

doAssert a.value == 0
doAssert b.value == 137
doAssert c.value == 137
```

## Generic Examples

It's also possible to use generics! Note that all connects are type checked by Nim.

```nim
connect(a, valueChanged,
        b, Counter[uint].setValue)

doAssert a.value == 0
doAssert b.value == 0

a.setValue(42) # we can directly call `setValue` which will then call emit

doAssert a.value == 42
doAssert b.value == 42
```

We can get / check signal types like this:

```nim
test "signal / slot types":
  doAssert SignalTypes.avgChanged(Counter[uint]) is (float, )
  doAssert SignalTypes.valueChanged(Counter[uint]) is (uint, )
  doAssert SignalTypes.setValue(Counter[uint]) is (uint, )
```

## Threads

Sigils 0.9+ can now do threaded signals! 

```nim
test "agent connect then moveToThread and run":
  var
    a = SomeAction.new()

  block:
    echo "sigil object thread connect change"
    var
      b = Counter.new()
      c = SomeAction.new()
    echo "thread runner!", " (th: ", getThreadId(), ")"
    let thread = newSigilThread()
    thread.start()
    startLocalThread()

    connect(a, valueChanged, b, setValue)
    connect(b, updated, c, SomeAction.completed())

    let bp: AgentProxy[Counter] = b.moveToThread(thread)
    echo "obj bp: ", bp.getSigilId()

    emit a.valueChanged(314)
    let ct = getCurrentSigilThread()
    ct[].poll() # we need to either `poll` or do `runForever` similar to async
    check c.value == 314
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
