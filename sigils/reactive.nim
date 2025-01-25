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

proc changed*[T](r: Sigil[T], val: T) {.signal.}
  ## core reactive signal type

proc setValue*[T](r: Sigil[T], val: T) {.slot.} =
  ## default slot action for `changed`
  r.val = val

proc `<-`*[T](s: Sigil[T], val: T) =
  if s.val != val:
    emit s.changed(val)

template newSigil*[T](x: T): Sigil[T] =
  block connectReactives:
    let r = Sigil[T](val: x)
    r.connect(changed, r, setValue)
    r

template computed*[T](blk: untyped): Sigil[T] =
  block:
    let res = Sigil[T]()
    func comp(res: Sigil[T]): T {.slot.} =
      res.val = block setupCallbacks:
        template `{}`(r: Sigil): auto {.inject.} =
          r.val
        `blk`
    let _ = block setupSignals:
      template `{}`(r: Sigil): auto {.inject.} =
        r.connect(changed, res, comp, acceptVoidSlot = true)
        r.val
      blk
    res
