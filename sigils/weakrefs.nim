import std/[hashes, isolation]

type DestructorUnsafe* = object ## input/output effect

type WeakRef*[T] {.acyclic.} = object
  # pt* {.cursor.}: T
  pt*: pointer
  ## type alias descring a weak ref that *must* be cleaned up
  ## when it's actual object is set to be destroyed

template `[]`*[T](r: WeakRef[T]): lent T =
  cast[T](r.pt)

proc unsafeWeakRef*[T](obj: T): WeakRef[T] =
  when defined(sigilsWeakRefCursor):
    result = WeakRef[T](pt: obj)
  else:
    result = WeakRef[T](pt: cast[pointer](obj))

proc verifyUnique*[T: WeakRef, V](field: T, parent: V) =
  discard # "verifyUnique: skipping weakref: ", $T

proc toPtr*[T](obj: WeakRef[T]): pointer =
  result = cast[pointer](obj.pt)

template toKind*[T, U](obj: WeakRef[T], tp: typedesc[U]): WeakRef[U] =
  cast[WeakRef[U]](U(obj[]))

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

when true:
  when defined(gcOrc):
    const
      rcMask = 0b1111
      rcShift = 4 # shift by rcShift to get the reference counter
  else:
    const
      rcMask = 0b111
      rcShift = 3 # shift by rcShift to get the reference counter

  type
    RefHeader = object
      rc: int
      when defined(gcOrc):
        rootIdx: int
          # thanks to this we can delete potential cycle roots
          # in O(1) without doubly linked lists

    Cell = ptr RefHeader

  template head[T](p: ref T): Cell =
    cast[Cell](cast[int](cast[pointer](p)) -% sizeof(RefHeader))

  template count(x: Cell): int =
    (x.rc shr rcShift)

  proc unsafeGcCount*[T](x: ref T): int =
    ## get the current gc count for ARC or ORC
    ## unsafe! Only intended for testing purposes!
    ## use `isUniqueRef` if you want to check a ref is unique
    if x.isNil:
      0
    else:
      x.head().count() + 1 # count of 0 means 1 ref, -1 is 0
