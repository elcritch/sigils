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
    fn: proc ()

proc changed*[T](r: Sigil[T]) {.signal.}
  ## core reactive signal type

proc recompute*[T](r: Sigil[T]) {.slot.} =
  ## default slot action for `changed`
  discard # TODO

proc `<-`*[T](s: Sigil[T], val: T) =
  if s.val != val:
    s.val = val
    emit s.changed()

template `{}`*[T](s: Sigil[T]): auto {.inject.} =
  when compiles(internalSigil is Sigil):
    echo "CONNECT"
    s.connect(changed, internalSigil, internalComputeSigil, acceptVoidSlot = true)
  echo "EXEC"
  s.val

template newSigil*[T](x: T): Sigil[T] =
  block connectReactives:
    let sigil = Sigil[T](val: x)
    sigil

template computed*[T](blk: untyped): Sigil[T] =
  block:
    let res = Sigil[T]()
    func internalComputeSigil(): T {.slot.} =
      res.val = block setupCallbacks:
        let internalSigil {.inject.} = res
        `blk`
    res.fn = internalComputeSigil
    res.apply()
    res
