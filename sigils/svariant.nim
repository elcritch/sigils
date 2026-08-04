include variant

import cloneutils

export cloneutils

type
  VariantCloner* = proc(
    value: Variant, mode: CloneMode
  ): Variant {.nimcall, gcsafe.}

proc newOwnedVariant*[T](value: sink T): Variant =
  result = VariantConcrete[T](
    typeId: getTypeId(T),
    val: ensureMove(value),
  )
  when defined(variantDebugTypes):
    result.mangledName = getMangledName(T)

proc cloneVariant[T](
    value: Variant, mode: CloneMode
): Variant {.nimcall, gcsafe.} =
  case mode
  of CloneMode.Deep:
    mixin clone
    result = newOwnedVariant(clone(value.get(T)))
  of CloneMode.Rc:
    result = newOwnedVariant(value.get(T))

proc clonerFor*[T](_: typedesc[T]): VariantCloner =
  cloneVariant[T]
