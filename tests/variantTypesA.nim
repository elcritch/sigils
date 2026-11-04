import sigils/svariant
import variantSharedTypes
export variantSharedTypes

type
  SameName* = object
    value*: int

proc integerIdA*(): TypeId = getTypeId(int)
proc boxedIntegerA*(): Variant = newVariant(42)
proc boxedContainerA*(): Variant = newVariant(Container[int](value: 17))

proc primitiveIdsA*(): seq[TypeId] =
  @[getTypeId(bool), getTypeId(char), getTypeId(int), getTypeId(int8),
    getTypeId(int64), getTypeId(uint), getTypeId(float32), getTypeId(float64),
    getTypeId(string), getTypeId(pointer), getTypeId(seq[int])]
