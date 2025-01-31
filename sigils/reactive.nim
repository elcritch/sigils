import sigils/signals
import sigils/slots
import sigils/core
import std/[sets]

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

  SigilEffectRegistry* = ref object of Agent
    effects: HashSet[SigilBase]

proc `$`*(s: SigilBase): string =
  result = "Sigil" 
  result &= $s.attrs

proc `$`*[T](s: Sigil[T]): string =
  result &= $(SigilBase(s))
  result &= "["
  result &= $(T)
  result &= "]"
  result &= "("
  result &= $(s.val)
  result &= ")"

proc isDirty*(s: SigilBase): bool =
  s.attrs.contains(Dirty)
proc isLazy*(s: SigilBase): bool =
  s.attrs.contains(Lazy)

proc changed*(s: SigilBase) {.signal.}
  ## core reactive signal type

proc near*[T](a, b: T, eps: T): bool =
  let diff = abs(a-b)
  result = diff <= eps

proc setValue*[T](s: Sigil[T], val: T) {.slot.} =
  ## slot to update sigil values, synonym of `<-`
  mixin near
  when T is SomeFloat:
    if not near(s.val, val, s.defaultEps):
      s.val = val
      emit s.changed()
  else:
    if s.val != val:
      s.val = val
      emit s.changed()

proc execute*(sigil: SigilBase) {.slot.} =
  echo "execute: ", sigil.unsafeWeakRef()
  sigil.fn(sigil)
  sigil.attrs.excl(Dirty)

proc recompute*(sigil: SigilBase) {.slot.} =
  ## default slot for updating sigils
  ## when `change` is emitted
  assert sigil.fn != nil
  echo "recompute: ", sigil.unsafeWeakRef()
  if Lazy in sigil.attrs:
    sigil.attrs.incl Dirty
    emit sigil.changed()
  else:
    sigil.fn(sigil)

proc `<-`*[T](s: Sigil[T], val: T) =
  ## update a static (non-computed) sigils value
  s.setValue(val)

template getInternalSigilIdent*(): untyped =
  ## overridable template to provide the ident
  ## that `{}` uses to look for the current 
  ## scoped to operate on – if one exists in
  ## this scope
  ## 
  ## for example `internalSigil` is used as the
  ## default identifier in `computed` block to
  ## connect dereferenced sigils to
  internalSigil

template `{}`*[T](sigil: Sigil[T]): auto {.inject.} =
  ## deferences a typed Sigil to get it's value 
  ## either from static sigils or computed sigils
  mixin getInternalSigilIdent
  when compiles(getInternalSigilIdent()):
    sigil.connect(changed, getInternalSigilIdent(), recompute)
  if Dirty in sigil.attrs:
    sigil.fn(sigil)
    sigil.attrs.excl(Dirty)
  sigil.val

proc newSigil*[T](value: T): Sigil[T] =
  ## create a new sigil
  result = Sigil[T](val: value)

template computedImpl[T](lazy, blk: untyped): Sigil[T] =
  block:
    let res = Sigil[T]()
    res.fn = proc(arg: SigilBase) {.closure.} =
      let internalSigil {.inject.} = Sigil[T](arg)
      let val = block:
        `blk`
      internalSigil.setValue(val)
    if lazy: res.attrs.incl Lazy
    res.recompute()
    res

template computedNow*[T](blk: untyped): Sigil[T] =
  ## returns a `computed` sigil that is eagerly evaluated
  computedImpl[T](false, blk)

template computed*[T](blk: untyped): Sigil[T] =
  ## returns a `computed` sigil that is lazily evaluated
  computedImpl[T](true, blk)

template `<==`*[T](tp: typedesc[T], blk: untyped): Sigil[T] =
  ## TODO: keep something like this?
  computedImpl[T](true, blk)


proc registerEffect*(agent: Agent, s: SigilBase) {.signal.}
  ## core signal for registering new effects

proc triggerEffects*(agent: Agent) {.signal.}
  ## core signal for trigger effects

iterator registered*(r: SigilEffectRegistry): SigilBase =
  for eff in r.effects:
    yield eff

iterator dirty*(r: SigilEffectRegistry): SigilBase =
  for eff in r.effects:
    if Dirty in eff.attrs:
      yield eff

proc onRegister*(reg: SigilEffectRegistry, s: SigilBase) {.slot.} =
  echo "onRegister"
  reg.effects.incl(s)

proc onTriggerEffects*(reg: SigilEffectRegistry) {.slot.} =
  for eff in reg.dirty:
    eff.execute()

proc initSigilEffectRegistry*(): SigilEffectRegistry =
  result = SigilEffectRegistry(effects: initHashSet[SigilBase]())
  connect(result, registerEffect, result, onRegister)
  connect(result, triggerEffects, result, onTriggerEffects)


template getSigilEffectsRegistry*(): untyped =
  ## identifier that is messaged with a new effect
  ## when it's created
  internalSigilEffectRegistry

template effect*(blk: untyped) =
  let res = SigilBase()
  res.fn = proc(arg: SigilBase) {.closure.} =
    let internalSigil {.inject.} = SigilBase(arg)
    `blk`
  echo "new-effect: ", res.unsafeWeakRef
  res.attrs.incl Lazy
  res.execute()
  emit getSigilEffectsRegistry().registerEffect(res)
