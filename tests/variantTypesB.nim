import sigils/svariant
import variantSharedTypes

type SameName* = object
  value*: int

proc integerIdB*(): TypeId = getTypeId(int)
proc readIntegerB*(value: Variant): int = value.get(int)
proc readContainerB*(value: Variant): int = value.get(Container[int]).value

proc primitiveIdsB*(): seq[TypeId] =
  @[getTypeId(bool), getTypeId(char), getTypeId(int), getTypeId(int8),
    getTypeId(int64), getTypeId(uint), getTypeId(float32), getTypeId(float64),
    getTypeId(string), getTypeId(pointer), getTypeId(seq[int])]
