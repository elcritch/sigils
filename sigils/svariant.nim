
import std/streams
import variant

type
  VBuffer* = object
    buff*: string

  WBuffer*[T] = VBuffer

  WVariant = Variant
  VConcrete[T] = ref object of Variant
    val: T

template getMangledName(t: typedesc): string = $t

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
  v.get(WBuffer[T]).asPtr()[]

proc resetTo*[T](v: Variant, val: sink T) =
  let sz = sizeof(val)
  v.typeId = getTypeId(WBuffer[T])
  when defined(variantDebugTypes):
    v.mangledName = getMangledName(T)

  cast[VConcrete[VBuffer]](v).val.buff.setLen(sz)
  v.get(WBuffer[T]).asPtr()[] = move val


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

