import sigils/signals
import sigils/slots
import sigils/core

export signals, slots, core

type
  Sigil*[T] = ref object of Agent
    ## Core *reactive* data type for doing reactive style programming
    ## akin to RXJS, React useState, Svelte, etc.
    ## 
    ## This builds on the core signals and slots but provides a
    ## higher level API for working with propagating values.
    val*: T
    fn: proc (): T {.closure.}

proc changed*[T](r: Sigil[T]) {.signal.}
  ## core reactive signal type

proc recompute*[T](sigil: Sigil[T]) {.slot.} =
  ## default slot action for `changed`
  if sigil.fn != nil:
    sigil.val = sigil.fn()

proc `<-`*[T](s: Sigil[T], val: T) =
  if s.val != val:
    echo "<-: ", s.unsafeWeakRef
    s.val = val
    emit s.changed()

template `{}`*[T](s: Sigil[T]): auto {.inject.} =
  when compiles(internalSigil is Sigil):
    echo "CONNECT:s: ", s.unsafeWeakRef()
    echo "CONNECT:sigil: ", internalSigil.unsafeWeakRef()
    s.connect(changed, internalSigil, Sigil[T].recompute)
  echo "EXEC: "
  s.val

template newSigil*[T](x: T): Sigil[T] =
  block connectReactives:
    let sigil = Sigil[T](val: x)
    sigil

template computed*[T](blk: untyped): Sigil[T] =
  block:
    let res = Sigil[T]()
    proc internalComputeSigil(): T {.closure.} =
      let internalSigil {.inject.} = res
      `blk`
    res.fn = internalComputeSigil
    res.recompute()
    res
