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

proc takeVariant*[T](value: Variant, _: typedesc[T]): T =
  ## Move a value out of an exclusively owned variant payload.
  ##
  ## Unlike `Variant.get`, this is destructive: callers must ensure that the
  ## variant is not retained for another delivery before using this proc.
  if value.isNil:
    raise newException(
      Exception, "Wrong variant type: nil. Expected type: " & getMangledName(T)
    )
  if getTypeId(T) == value.typeId:
    let concrete = cast[VariantConcrete[T]](value)
    # `ensureMove` cannot prove exclusivity through the Variant reference;
    # this is the consuming boundary, so force the field move explicitly.
    result = move(concrete.val)
    value.typeId = 0
    when debugVariantTypes:
      value.mangledName.setLen(0)
    return

  when debugVariantTypes:
    raise newException(
      Exception,
      "Wrong variant type: " & value.mangledName & ". Expected type: " &
        getMangledName(T),
    )
  else:
    raise newException(
      Exception,
      "Wrong variant type. Compile with -d:variantDebugTypes switch to get more type information.",
    )

proc cloneVariant[T](value: Variant, mode: CloneMode): Variant {.nimcall, gcsafe.} =
  case mode
  of CloneMode.Deep:
    mixin clone
    result = newOwnedVariant(clone(value.get(T)))
  of CloneMode.Rc:
    result = newOwnedVariant(value.get(T))

proc clonerFor*[T](_: typedesc[T]): VariantCloner =
  cloneVariant[T]
