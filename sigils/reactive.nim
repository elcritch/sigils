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

proc changed*[T](r: Sigil[T]) {.signal.}
  ## core reactive signal type

proc recompute*[T](r: Sigil[T]) {.slot.} =
  ## default slot action for `changed`
  # r.val = val
  discard # TODO

proc `<-`*[T](s: Sigil[T], val: T) =
  if s.val != val:
    s.val = val
    emit s.changed()

template newSigil*[T](x: T): Sigil[T] =
  block connectReactives:
    let sigil = Sigil[T](val: x)
    sigil

template computed*[T](blk: untyped): Sigil[T] =
  block:
    let res = Sigil[T]()
    func comp(res: Sigil[T]): T {.slot.} =
      res.val = block setupCallbacks:
        template `{}`(r: Sigil): auto {.inject.} =
          r.val
        `blk`
    res.val = block setupSignals:
      template `{}`(r: Sigil): auto {.inject.} =
        r.connect(changed, res, comp, acceptVoidSlot = true)
        r.val
      blk
    res
