import sigils/signals
import sigils/slots
import sigils/core
import std/[math, sets]

export signals, slots, core

type
  SigilAttributes* = enum
    Dirty
    Lazy

  SigilBase* = ref object of Agent
    attrs: set[SigilAttributes]
    fn: proc (arg: SigilBase) {.closure.}

  Sigil*[T] = ref object of SigilBase
    ## Core *reactive* data type for doing reactive style programming
    ## akin to RXJS, React useState, Svelte, etc.
    ## 
    ## This builds on the core signals and slots but provides a
    ## higher level API for working with propagating values.
    val: T
    when T is float or T is float32:
      defaultEps* = 1.0e-5
    elif T is float64:
      defaultEps* = 1.0e-10

# proc `val=`*[T](s: Sigil[T], val: T) = {.error: "cannot set value directly, use `<-`".}
# proc `val`*[T](s: Sigil[T]): T = s.val

proc changed*[T](r: Sigil[T]) {.signal.}
  ## core reactive signal type

proc near*[T](a, b: T, eps: T): bool =
  let diff = abs(a-b)
  result = diff <= eps

proc setValue*[T](s: Sigil[T], val: T) =
  mixin near
  when T is SomeFloat:
    if not near(s.val, val, s.defaultEps):
      s.val = val
      emit s.changed()
  else:
    if s.val != val:
      s.val = val
      emit s.changed()

proc recompute*(sigil: SigilBase) {.slot.} =
  ## default slot action for `changed`
  assert sigil.fn != nil
  if Lazy in sigil.attrs:
    sigil.attrs.incl Dirty
  else:
    sigil.fn(sigil)

proc `<-`*[T](s: Sigil[T], val: T) =
  s.setValue(val)

template `{}`*[T](sigil: Sigil[T]): auto {.inject.} =
  when compiles(internalSigil):
    sigil.connect(changed, internalSigil, recompute)
  if Dirty in sigil.attrs:
    sigil.fn(sigil)
    sigil.attrs.excl(Dirty)
  sigil.val

template newSigil*[T](value: T): Sigil[T] =
  block connectReactives:
    let sigil = Sigil[T](val: value)
    sigil

template computedImpl*[T](lazy, blk: untyped): Sigil[T] =
  block:
    let res = Sigil[T]()
    if lazy:
      res.attrs.incl Lazy
    res.fn = proc(arg: SigilBase) {.closure.} =
      let internalSigil {.inject.} = Sigil[T](arg)
      let val = block:
        `blk`
      internalSigil.setValue(val)
    res.recompute()
    res

template computed*[T](blk: untyped): Sigil[T] =
  computedImpl[T](false, blk)

template computedLazy*[T](blk: untyped): Sigil[T] =
  computedImpl[T](true, blk)
