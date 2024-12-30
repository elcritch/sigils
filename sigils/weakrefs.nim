import std/[hashes, isolation]

type DestructorUnsafe* = object ## input/output effect

type WeakRef*[T] {.acyclic.} = object
  # pt* {.cursor.}: T
  pt*: pointer
  ## type alias descring a weak ref that *must* be cleaned
  ## up when an object is set to be destroyed

template `[]`*[T](r: WeakRef[T]): lent T =
  cast[T](r.pt)

proc toPtr*[T](obj: WeakRef[T]): pointer =
  result = cast[pointer](obj.pt)

proc hash*[T](obj: WeakRef[T]): Hash =
  result = hash cast[pointer](obj.pt)

template withRef*[T: ref](obj: WeakRef[T], name: untyped) {.tags: [DestructorUnsafe].} =
  block:
    var `name` {.inject.} = cast[T](obj)
    # GC_ref(result)
    ## since we create a new ref instance "out of nowhere" we need to manually GC_ref it

template withRef*[T: ref](obj: T, name: untyped): T =
  result = obj

proc isolate*[T](obj: WeakRef[T]): Isolated[WeakRef[T]] =
  result = unsafeIsolate(obj)

proc `$`*[T](obj: WeakRef[T]): string =
  result = "Weak[" & $(T) & "]"
  result &= "(0x"
  result &= obj.toPtr().repr
  result &= ")"
