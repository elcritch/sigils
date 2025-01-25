import sigils/signals
import sigils/slots
import sigils/core

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

proc changed*[T](r: Sigil[T]) {.signal.}
  ## core reactive signal type

proc recompute*(sigil: SigilBase) {.slot.} =
  ## default slot action for `changed`
  if sigil.fn != nil:
    # sigil.val = sigil.fn(sigil)
    sigil.fn(sigil)

proc `<-`*[T](s: Sigil[T], val: T) =
  if s.val != val:
    # echo "\n<-: ", s.unsafeWeakRef
    s.val = val
    emit s.changed()

var isRunningInternally {.compileTime.} = false

template `{}`*[T](sigil: Sigil[T]): auto {.inject.} =
  when isRunningInternally:
    sigil.connect(changed, internalSigil, recompute)
  sigil.val

template newSigil*[T](x: T): Sigil[T] =
  block connectReactives:
    let sigil = Sigil[T](val: x)
    sigil

template computed*[T](blk: untyped): Sigil[T] =
  block:
    static:
      isRunningInternally = true
    let res = Sigil[T]()
    # echo "\n\nCOMPUTE:INTERNALCOMPUTESIGIL: ", res.unsafeWeakRef
    res.fn = proc(arg: SigilBase) {.closure.} =
      let internalSigil {.inject.} = Sigil[T](arg)
      let val = block:
        `blk`
      if internalSigil.val != val:
        internalSigil.val = val
        emit internalSigil.changed()
    res.recompute()
    static:
      isRunningInternally = false
    res
