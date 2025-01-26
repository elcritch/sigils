import sigils/signals
import sigils/slots
import sigils/core
import std/math

export signals, slots, core

type
  SigilBase* = ref object of Agent
    fn: proc (arg: SigilBase) {.closure.}

  Sigil*[T] = ref object of SigilBase
    ## Core *reactive* data type for doing reactive style programming
    ## akin to RXJS, React useState, Svelte, etc.
    ## 
    ## This builds on the core signals and slots but provides a
    ## higher level API for working with propagating values.
    val*: T
    when T is float or T is float32:
      defaultPrecision* = 5
    elif T is float64:
      defaultPrecision* = 10

proc changed*[T](r: Sigil[T]) {.signal.}
  ## core reactive signal type

proc setValue*[T](s: Sigil[T], val: T) =
  when T is SomeFloat:
    if almostEqual(s.val, val, s.defaultPrecision):
      s.val = val
      emit s.changed()
  else:
    if s.val != val:
      s.val = val
      emit s.changed()

proc recompute*(sigil: SigilBase) {.slot.} =
  ## default slot action for `changed`
  if sigil.fn != nil:
    sigil.fn(sigil)

proc `<-`*[T](s: Sigil[T], val: T) =
  s.setValue(val)

template `{}`*[T](sigil: Sigil[T]): auto {.inject.} =
  when compiles(internalSigil):
    sigil.connect(changed, internalSigil, recompute)
  sigil.val

template newSigil*[T](x: T): Sigil[T] =
  block connectReactives:
    let sigil = Sigil[T](val: x)
    sigil

template computed*[T](blk: untyped): Sigil[T] =
  block:
    let res = Sigil[T]()
    # echo "\n\nCOMPUTE:INTERNALCOMPUTESIGIL: ", res.unsafeWeakRef
    res.fn = proc(arg: SigilBase) {.closure.} =
      let internalSigil {.inject.} = Sigil[T](arg)
      let val = block:
        `blk`
      internalSigil.setValue(val)
    res.recompute()
    res
