import std/[hashes, isolation]

type DestructorUnsafe* = object ## input/output effect

type WeakRef*[T] {.acyclic.} = object
  # pt* {.cursor.}: T
  pt*: pointer
  ## type alias descring a weak ref that *must* be cleaned up
  ## when it's actual object is set to be destroyed

template `[]`*[T](r: WeakRef[T]): lent T =
  cast[T](r.pt)

proc verifyUnique*[T: WeakRef, V](field: T, parent: V) =
  discard # "verifyUnique: skipping weakref: ", $T

proc toPtr*[T](obj: WeakRef[T]): pointer =
  result = cast[pointer](obj.pt)

proc hash*[T](obj: WeakRef[T]): Hash =
  result = hash cast[pointer](obj.pt)

template withRef*[T: ref](obj: WeakRef[T], name, blk: untyped) =
  block:
    var `name` {.inject.} = obj[]
    `blk`

template withRef*[T: ref](obj: T, name, blk: untyped) =
  block:
    var `name` {.inject.} = obj
    `blk`

proc isolate*[T](obj: WeakRef[T]): Isolated[WeakRef[T]] =
  result = unsafeIsolate(obj)

proc `$`*[T](obj: WeakRef[T]): string =
  result = "Weak[" & $(T) & "]"
  result &= "(0x"
  result &= obj.toPtr().repr
  result &= ")"
