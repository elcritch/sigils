
import std/streams
include variant

type
  VBuffer* = object
    buff*: string

  WBuffer*[T] = VBuffer
  WVariant* = Variant

proc asPtr*[T](wt: WBuffer[T]): ptr T =
  static: assert sizeof(T) > 0
  cast[ptr T](addr(wt.buff[0]))

proc initWrapper*[T](val: sink T): WBuffer[T] =
  let sz = sizeof(val)
  result.buff.setLen(sz)
  result.asPtr()[] = move val

proc newWrapperVariant*[T](val: sink T): WVariant =
  newVariant(initWrapper(val))

proc getWrapped*(v: Variant, T: typedesc): T =
  cast[VariantConcrete[WBuffer[T]]](v).val.asPtr()[]

proc resetTo*[T](v: WVariant, val: T) =
  let sz = sizeof(val)
  v.typeId = getTypeId(WBuffer[T])
  when defined(variantDebugTypes):
    v.mangledName = getMangledName(T)

  if cast[VariantConcrete[VBuffer]](v).val.buff.len() < sz:
    cast[VariantConcrete[VBuffer]](v).val.buff.setLen(sz)
  cast[VariantConcrete[WBuffer[T]]](v).val.asPtr()[] = val

when isMainModule:

  import std/unittest

  test "basic":
    var x: int16 = 7
    echo "x: ", x

    let vx = newVariant(initWrapper(x))
    echo "=> vx: ", vx.getWrapped(int16)
    check x == vx.getWrapped(int16)

    var y: array[1024, int]
    y[0] = 0xAA
    y[^1] = 0xFF
    echo "y: ", y[0]

    vx.resetTo(y)
    echo "=> vy: ", vx.getWrapped(array[1024, int])

    var z: int = 16
    echo "z: ", z

    vx.resetTo(z)
    echo "=> vz: ", vx.getWrapped(int)

  test "wrapper":
    var x: int16 = 7
    echo "x: ", x

    let vx = newWrapperVariant(x)
    echo "=> vx: ", vx.getWrapped(int16)
    check x == vx.getWrapped(int16)

