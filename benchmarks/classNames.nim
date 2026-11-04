## Single-threaded subclass control for the name-storage experiment.
## Ordinary ARC refs are deliberately NOT a supported cross-thread name backend.
import std/hashes

type
  ClassName* = ref object of RootObj
    length: int
  LiteralName = ref object of ClassName
    bytes: cstring
  DynamicName = ref object of ClassName
    text: string

method bytes(value: ClassName): cstring {.base.} = nil
method bytes(value: LiteralName): cstring = value.bytes
method bytes(value: DynamicName): cstring = value.text.cstring

proc initClassName*(value: static string): ClassName =
  let shared {.global.} = LiteralName(length: value.len, bytes: cstring(value))
  shared

proc initClassName*(value: string): ClassName =
  DynamicName(length: value.len, text: value)

proc len*(value: ClassName): int {.inline.} =
  if value.isNil: 0 else: value.length

proc `$`*(value: ClassName): string =
  result = newString(value.len)
  if result.len > 0:
    copyMem(addr result[0], value.bytes, result.len)

proc `==`*(a, b: ClassName): bool =
  if cast[pointer](a) == cast[pointer](b): return true
  a.len == b.len and (a.len == 0 or equalMem(a.bytes, b.bytes, a.len))

proc cmp*(a, b: ClassName): int =
  let common = min(a.len, b.len)
  if common > 0:
    result = cmpMem(a.bytes, b.bytes, common)
    if result != 0: return
  result = cmp(a.len, b.len)

proc hash*(value: ClassName): Hash =
  if value.len == 0: return hash("")
  hash(toOpenArray(value.bytes, 0, value.len - 1))
