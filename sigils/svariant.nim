include variant

import cloneutils

export cloneutils

type
  VariantCloner* = proc(value: Variant): Variant {.nimcall, gcsafe.}

proc newOwnedVariant*[T](value: sink T): Variant =
  result = VariantConcrete[T](
    typeId: getTypeId(T),
    val: ensureMove(value),
  )
  when defined(variantDebugTypes):
    result.mangledName = getMangledName(T)

proc cloneVariant[T](value: Variant): Variant {.nimcall, gcsafe.} =
  mixin clone
  newOwnedVariant(clone(value.get(T)))

proc clonerFor*[T](_: typedesc[T]): VariantCloner =
  cloneVariant[T]
