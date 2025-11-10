
import std/streams
import variant

type
  VBuffer* = object
    buff*: string

  WBuffer*[T] = VBuffer

proc asPtr*[T](wt: WBuffer[T]): ptr T =
  static: assert sizeof(T) > 0
  cast[ptr T](addr(wt.buff[0]))

proc initWrapper*[T](val: sink T): WBuffer[T] =
  let sz = sizeof(val)
  result.buff.setLen(sz)
  result.asPtr()[] = move val

proc getWrapped*(v: Variant, T: typedesc): T =
  v.get(WBuffer[T]).asPtr()[]

when isMainModule:

  import std/unittest

  test "basic":
    var x: int = 7
    echo "x: ", x

    let vx = newVariant(initWrapper(x))
    echo "=> vx: ", vx.getWrapped(int)
    check x == vx.getWrapped(int)
