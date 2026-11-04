## Subclass alternative with static descriptors and atomic dynamic ownership.
## Unlike classNames, literal descriptors live in globals, not on the heap.
import std/[atomics, hashes]

type
  NameStorage = object of RootObj
    length: int
    bytes: cstring
  LiteralStorage = object of NameStorage
  DynamicStorage = object of NameStorage
    owners: Atomic[int]
  DescriptorName* = object
    storage: ptr NameStorage

proc retain(value: DescriptorName) =
  if value.storage != nil and value.storage[] of DynamicStorage:
    discard cast[ptr DynamicStorage](value.storage).owners.fetchAdd(1, moRelaxed)

proc `=destroy`*(value: DescriptorName) =
  if value.storage != nil and value.storage[] of DynamicStorage:
    let owned = cast[ptr DynamicStorage](value.storage)
    if owned.owners.fetchSub(1, moAcquireRelease) == 1:
      deallocShared(owned)

proc `=copy`*(dest: var DescriptorName, source: DescriptorName) =
  retain(source)
  `=destroy`(dest)
  dest.storage = source.storage

proc `=dup`*(source: DescriptorName): DescriptorName =
  retain(source)
  result.storage = source.storage

proc initDescriptorName*(value: static string): DescriptorName =
  var descriptor {.global.} = LiteralStorage(length: value.len, bytes: cstring(value))
  result.storage = addr descriptor

proc initDescriptorName*(value: string): DescriptorName =
  if value.len == 0: return
  let owned = cast[ptr DynamicStorage](allocShared0(sizeof(DynamicStorage) +
      value.len + 1))
  owned[] = DynamicStorage(length: value.len)
  owned.owners.store(1, moRelaxed)
  owned.bytes = cast[cstring](cast[uint](owned) + uint(sizeof(DynamicStorage)))
  copyMem(owned.bytes, unsafeAddr value[0], value.len)
  result.storage = owned

proc len*(value: DescriptorName): int {.inline.} =
  if value.storage == nil: 0 else: value.storage.length

proc `$`*(value: DescriptorName): string =
  result = newString(value.len)
  if result.len > 0:
    copyMem(addr result[0], value.storage.bytes, result.len)

proc `==`*(a, b: DescriptorName): bool =
  if a.storage == b.storage: return true
  a.len == b.len and (a.len == 0 or equalMem(a.storage.bytes, b.storage.bytes, a.len))

proc cmp*(a, b: DescriptorName): int =
  let common = min(a.len, b.len)
  if common > 0:
    result = cmpMem(a.storage.bytes, b.storage.bytes, common)
    if result != 0: return
  result = cmp(a.len, b.len)

proc hash*(value: DescriptorName): Hash =
  if value.len == 0: return hash("")
  hash(toOpenArray(value.storage.bytes, 0, value.len - 1))
