## Immutable names with borrowed literal storage and atomically shared runtime
## storage. Only the static-string constructor borrows; runtime strings copy.
import std/[atomics, hashes]

type
  NameHeader = object
    owners: Atomic[int]
  SharedName* = object
    data: cstring
    # Nonnegative: static bytes. Negative: owned bytes, length = -count.
    count: int

when defined(sigilsNameMetrics):
  var nameAllocations, nameReleases, nameRetains: Atomic[int]
  proc sharedNameMetrics*(): tuple[allocations, releases, retains: int] =
    (nameAllocations.load(), nameReleases.load(), nameRetains.load())

proc header(value: SharedName): ptr NameHeader {.inline.} =
  cast[ptr NameHeader](cast[uint](value.data) - uint(sizeof(NameHeader)))

proc `=destroy`*(value: SharedName) =
  when nimvm:
    discard
  else:
    if value.count < 0:
      let allocation = value.header
      if allocation.owners.fetchSub(1, moAcquireRelease) == 1:
        when defined(sigilsNameMetrics):
          discard nameReleases.fetchAdd(1, moRelaxed)
        deallocShared(allocation)

proc retain(value: SharedName) {.inline.} =
  when nimvm:
    discard
  else:
    if value.count < 0:
      discard value.header.owners.fetchAdd(1, moRelaxed)
      when defined(sigilsNameMetrics):
        discard nameRetains.fetchAdd(1, moRelaxed)

proc `=copy`*(dest: var SharedName, source: SharedName) =
  retain(source)
  `=destroy`(dest)
  dest.data = source.data
  dest.count = source.count

proc `=dup`*(source: SharedName): SharedName =
  retain(source)
  result.data = source.data
  result.count = source.count

proc initSharedName*(value: static string): SharedName {.inline.} =
  ## Borrow bytes with executable lifetime, without allocating or retaining.
  static:
    doAssert '\0' notin value, "SharedName cannot contain NUL bytes"
  SharedName(data: cstring(value), count: value.len)

func initSharedName*(value: string): SharedName =
  ## Copy runtime bytes into one allocation shared by subsequent name copies.
  if value.len == 0:
    return
  if '\0' in value:
    raise newException(ValueError, "SharedName cannot contain NUL bytes")
  # The allocation is fresh and unpublished; only its private owner count changes.
  {.cast(noSideEffect).}:
    let allocation = cast[ptr NameHeader](allocShared(
      sizeof(NameHeader) + value.len + 1))
    allocation.owners.store(1, moRelaxed)
    let data = cast[cstring](cast[uint](allocation) + uint(sizeof(NameHeader)))
    copyMem(data, unsafeAddr value[0], value.len)
    cast[ptr UncheckedArray[char]](data)[value.len] = '\0'
    result = SharedName(data: data, count: -value.len)
    when defined(sigilsNameMetrics):
      discard nameAllocations.fetchAdd(1, moRelaxed)

func len*(value: SharedName): int {.inline.} =
  if value.count < 0: -value.count else: value.count

proc `$`*(value: SharedName): string =
  result = newString(value.len)
  if result.len > 0:
    when nimvm:
      for index in 0 ..< result.len:
        result[index] = value.data[index]
    else:
      copyMem(addr result[0], value.data, result.len)

proc `==`*(a, b: SharedName): bool {.inline.} =
  if a.len != b.len:
    return false
  if a.len == 0:
    return true
  when nimvm:
    $a == $b
  else:
    cast[pointer](a.data) == cast[pointer](b.data) or
      equalMem(a.data, b.data, a.len)

proc `==`*(a: SharedName, b: string): bool {.inline.} =
  if a.len != b.len:
    return false
  if a.len == 0:
    return true
  when nimvm:
    $a == b
  else:
    equalMem(a.data, unsafeAddr b[0], a.len)

proc `==`*(a: string, b: SharedName): bool {.inline.} = b == a

proc startsWith*(value: SharedName, prefix: string): bool =
  if prefix.len > value.len:
    return false
  if prefix.len == 0:
    return true
  when nimvm:
    for index in 0 ..< prefix.len:
      if value.data[index] != prefix[index]:
        return false
    true
  else:
    equalMem(value.data, unsafeAddr prefix[0], prefix.len)

proc cmp*(a, b: SharedName): int =
  let common = min(a.len, b.len)
  if common > 0:
    when nimvm:
      for index in 0 ..< common:
        result = cmp(a.data[index], b.data[index])
        if result != 0:
          return
    else:
      result = cmpMem(a.data, b.data, common)
    if result != 0:
      return
  result = cmp(a.len, b.len)

proc `<`*(a, b: SharedName): bool {.inline.} = cmp(a, b) < 0
proc `<=`*(a, b: SharedName): bool {.inline.} = cmp(a, b) <= 0

proc hash*(value: SharedName): Hash =
  if value.len == 0:
    return hash("")
  when nimvm:
    hash($value)
  else:
    hash(toOpenArray(value.data, 0, value.len - 1))

proc clone*(value: SharedName): SharedName {.inline.} =
  ## Immutable bytes and atomic ownership allow sharing across delivery threads.
  value
