# Sigils

A [signal and slots library](https://en.wikipedia.org/wiki/Signals_and_slots) implemented for the Nim programming language. The signals and slots are type checked and implemented purely in Nim.

Note that this implementation shares many or most of the limitations you'd see in Qt's implementation. Sigils currently only has rudimentary multi-threading, but I hope to expand them over time.

## Examples

Here's an example usage:

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

