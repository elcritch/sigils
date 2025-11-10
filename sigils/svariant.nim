
import std/streams
import variant

type
  VBuffer* = object
    buff*: string

  WBuffer*[T] = VBuffer

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

proc getWrapped*(v: Variant, T: typedesc): T =
  v.get(WBuffer[T]).asPtr()[]

proc resetTo*[T](v: Variant, val: sink T) =
  let sz = sizeof(val)
  v.typeId = getTypeId(WBuffer[T])
  when defined(variantDebugTypes):
    v.mangledName = getMangledName(T)

  # cast[VConcrete[VBuffer]](v).val.buff.setLen(sz)
  # v.get(VBuffer).buff.setLen(sz)
  v.get(WBuffer[T]).asPtr()[] = move val


when isMainModule:

  import std/unittest

  test "basic":
    var x: int16 = 7
    echo "x: ", x

    let vx = newVariant(initWrapper(x))
    echo "=> vx: ", vx.getWrapped(int16)
    check x == vx.getWrapped(int16)

    var y: array[50, int]
    y[0] = 0xAA
    echo "y: ", y[0]

    vx.resetTo(y)
    echo "=> vy: ", vx.getWrapped(array[50, int])
