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

  SigilHashed* = ref object of SigilBase
    vhash: Hash

  Sigil*[T] = ref object of SigilHashed
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
  result &= "#"
  result &= $(s.vhash)
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
      s.vhash = hash(val)
      s.attrs.excl(Dirty)
      emit s.changed()
  else:
    if s.val != val:
      s.val = val
      s.attrs.excl(Dirty)
      s.vhash = hash(val)
      emit s.changed()

proc execute*(sigil: SigilBase) {.slot.} =
  echo "execute: ", sigil.unsafeWeakRef()
  if sigil.isLazy() and sigil.isDirty():
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
    # echo "recompute:execute: ", sigil.unsafeWeakRef()
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
  result = Sigil[T](val: value, vhash: hash(value))

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
  reg.effects.incl(s)

proc onTriggerEffects*(reg: SigilEffectRegistry) {.slot.} =
  echo "onTriggerEffects"
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

proc computeHash(sigil: SigilHashed): Hash =
  var vhash: Hash = 0
  for listened in sigil.listening:
    if listened[] of SigilHashed:
      withRef(listened, item):
        let sh = SigilHashed(item)
        let prev = sh.vhash
        sh.execute()
        echo "\tEFF:changed: ", prev, " <> ", sh.vhash
        vhash = vhash !& sh.vhash
        # if prev != sh.vhash:
        #   sigil.attrs.incl Changed
  return !$ vhash

proc computeChanged(sigil: SigilHashed) =
  ## computes changes for effects
  ## note: Nim ref's default to pointer hashes, not content hashes
  let vhash = computeHash(sigil)
  echo "\tEFF:computeChanged: ", vhash, " <> ", sigil.vhash
  if vhash != sigil.vhash:
    sigil.attrs.incl Changed
  sigil.vhash = vhash

template effect*(blk: untyped) =
  let res = SigilHashed()
  res.fn = proc(arg: SigilBase) {.closure.} =
    let internalSigil {.inject.} = SigilHashed(arg)
    echo "\tEFF:CALLBACK: "
    internalSigil.computeChanged()
    if Changed in internalSigil.attrs:
      echo "effect dirty!"
      `blk`
      internalSigil.attrs.excl {Dirty, ChangeD}
      internalSigil.vhash = internalSigil.computeHash()
    else:
      echo "effect clean!"
  echo "new-effect: ", res
  res.attrs.incl Dirty
  res.attrs.incl Lazy
  res.attrs.incl Changed
  res.execute()
  echo "new-effect:post:exec: ", res
  emit getSigilEffectsRegistry().registerEffect(res)
