import sigils/signals
import sigils/slots
import sigils/core
import std/[sets, hashes]

export signals, slots, core

type
  SigilAttributes* = enum
    Dirty
    Lazy
    Changed

  SigilBase* = ref object of Agent
    attrs: set[SigilAttributes]
    fn: proc (arg: SigilBase) {.closure.}

  SigilEffect* = ref object of SigilBase
    change: HashSet[SigilBase]

  Sigil*[T] = ref object of SigilBase
    ## Core *reactive* data type for doing reactive style programming
    ## akin to RXJS, React useState, Svelte, etc.
    ## 
    ## This builds on the core signals and slots but provides a
    ## higher level API for working with propagating values.
    val: T

  SigilEffectRegistry* = ref object of Agent
    effects: HashSet[SigilEffect]

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

proc change*(s: SigilBase, attrs: set[SigilAttributes]) {.signal.}
  ## core reactive signal type


proc near*[T](a, b: T): bool =
  let diff = abs(a-b)
  when T is float or T is float32:
    let eps = 1.0e-5
  elif T is float64:
    let eps = 1.0e-10
  result = diff <= eps

proc setValue*[T](s: Sigil[T], val: T) {.slot.} =
  ## slot to update sigil values, synonym of `<-`
  mixin near
  when T is SomeFloat:
    if not near(s.val, val):
      s.val = val
      s.attrs.excl(Dirty)
      emit s.change({Dirty})
  else:
    if s.val != val:
      s.val = val
      s.attrs.excl(Dirty)
      emit s.change({Changed})

proc compute*(sigil: SigilBase) {.slot.} =
  # echo "compute: ", sigil.unsafeWeakRef()
  if sigil.isLazy() and sigil.isDirty():
    sigil.fn(sigil)
    sigil.attrs.excl(Dirty)

proc recompute*(sigil: SigilBase, attrs: set[SigilAttributes]) {.slot.} =
  ## default slot for updating sigils
  ## when `change` is emitted
  assert sigil.fn != nil
  echo "recompute: ", sigil.unsafeWeakRef(), " got: ", attrs
  if Lazy in sigil.attrs:
    sigil.attrs.incl Dirty
    sigil.attrs.incl({Changed} * attrs)
    emit sigil.change({Dirty})
  else:
    # echo "recompute:compute: ", sigil.unsafeWeakRef()
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
    sigil.connect(change, getInternalSigilIdent(), recompute)
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
    res.recompute({})
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


proc registerEffect*(agent: Agent, s: SigilEffect) {.signal.}
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

proc onRegister*(reg: SigilEffectRegistry, s: SigilEffect) {.slot.} =
  reg.effects.incl(s)

proc onTriggerEffects*(reg: SigilEffectRegistry) {.slot.} =
  # echo "onTriggerEffects"
  for eff in reg.dirty:
    eff.compute()

proc initSigilEffectRegistry*(): SigilEffectRegistry =
  result = SigilEffectRegistry(effects: initHashSet[SigilEffect]())
  connect(result, registerEffect, result, onRegister)
  connect(result, triggerEffects, result, onTriggerEffects)


template getSigilEffectsRegistry*(): untyped =
  ## identifier that is messaged with a new effect
  ## when it's created
  internalSigilEffectRegistry

proc computeDeps(sigil: SigilEffect) =
  for listened in sigil.listening:
    echo "EFF:deps: ", listened
    if listened[] of SigilBase:
      withRef(listened, item):
        let sh = SigilBase(item)
        echo "EFF:deps:item: ", sh
        sh.compute()

proc computeChanged(sigil: SigilEffect) =
  ## computes changes for effects
  ## note: Nim ref's default to pointer hashes, not content hashes
  # let vhash = computeHash(sigil)
  # echo "\tEFF:computeChanged: ", vhash, " <> ", sigil.vhash
  # if vhash != sigil.vhash:
  #   sigil.attrs.incl Changed
  # sigil.vhash = vhash
  discard

template effect*(blk: untyped) =
  let res = SigilEffect()
  when defined(sigilsDebug):
    res.debugName = "EFF"
  res.fn = proc(arg: SigilBase) {.closure.} =
    let internalSigil {.inject.} = SigilEffect(arg)
    # internalSigil.computeChanged()
    echo "\nEFFECT:recompute: ", internalSigil.unsafeWeakRef()
    internalSigil.computeDeps()
    if Changed in internalSigil.attrs:
      `blk`
      internalSigil.attrs.excl {Dirty, ChangeD}
      # internalSigil.vhash = internalSigil.computeHash()
  res.attrs.incl {Dirty, Lazy, Changed}
  res.compute()
  emit getSigilEffectsRegistry().registerEffect(res)
