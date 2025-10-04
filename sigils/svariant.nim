
import std/streams
import variant

type
  SVariant* = object of RootObj
    typeId*: TypeId
    when defined(variantDebugTypes):
      mangledName*: string

  SVariantInline*[T] = object of SVariant
    val*: T

  SVariantBuffer*[T] = object of SVariant
    val*: T


when isMainModule:

  import std/unittest

  test "basic":
    var x = 7

    var ss = newStringStream()
    echo "sizeof: SVariant[int]: ", sizeof(x)
    ss.data.setLen(sizeof(x))

    template asPtr[T](data: string, tp: typedesc[T]): ptr SVariant[T] =
      cast[ptr SVariant[T]](addr(data[0]))
    
    let sx = ss.data.asPtr(int)
    sx[].typeId = getTypeId(int)
    sx[].val = x

    echo "sx: ", sx.repr
