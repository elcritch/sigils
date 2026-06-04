import std/[algorithm, tables]

import protocol

type
  HybridSigilTableKind* = enum
    hstSmall
    hstLarge

  HybridSigilTableEntry[Value] = object
    key: SigilName
    values: seq[Value]

  HybridSigilTableItem*[Value] = tuple[key: SigilName, value: Value]

  HybridRemoveAction* = enum
    hraKeep
    hraFound
    hraDelete

  HybridMatchPredicate*[Value] =
    proc(value: Value): bool {.closure, gcsafe, raises: [].}
  HybridRemovePredicate*[Value] =
    proc(value: Value): HybridRemoveAction {.closure, gcsafe, raises: [].}

  HybridSigilTable*[Value; threshold: static[int]] = object
    ## Sigil-keyed multimap that keeps a sorted seq for small key counts and
    ## promotes to a hash table once selector/subscription lookups are larger.
    valueCount: int
    kind*: HybridSigilTableKind
    small: seq[HybridSigilTableEntry[Value]]
    large: Table[SigilName, seq[Value]]

func compareSigilName*(a, b: SigilName): int {.inline.} =
  let minLen = min(a.len, b.len)
  var idx = 0
  while idx < minLen:
    if a.data[idx] < b.data[idx]:
      return -1
    if a.data[idx] > b.data[idx]:
      return 1
    idx.inc()

  if a.len < b.len:
    -1
  elif a.len > b.len:
    1
  else:
    0

func useSmallStorage[threshold: static[int]](keyCount: int): bool {.inline.} =
  threshold > 0 and keyCount < threshold

proc lowerBoundEntry[Value](
    entries: openArray[HybridSigilTableEntry[Value]], key: SigilName
): int {.inline, gcsafe, raises: [].} =
  var
    lo = 0
    hi = entries.len
  while lo < hi:
    let mid = (lo + hi) shr 1
    if compareSigilName(entries[mid].key, key) < 0:
      lo = mid + 1
    else:
      hi = mid
  lo

proc entryIndex[Value; threshold: static[int]](
    entries: openArray[HybridSigilTableEntry[Value]], key: SigilName
): int {.inline, gcsafe, raises: [].} =
  if useSmallStorage[threshold](entries.len):
    var idx = 0
    while idx < entries.len:
      if entries[idx].key == key:
        return idx
      idx.inc()
    return -1

  let idx = lowerBoundEntry(entries, key)
  if idx < entries.len and entries[idx].key == key:
    idx
  else:
    -1

proc promote[Value; threshold: static[int]](
    table: var HybridSigilTable[Value, threshold]
) {.gcsafe, raises: [].} =
  case table.kind
  of hstLarge:
    return
  of hstSmall:
    discard

  if useSmallStorage[threshold](table.small.len):
    return

  var large: Table[SigilName, seq[Value]]
  for item in table.small:
    large[item.key] = item.values
  table.small.setLen(0)
  table.large = large
  table.kind = hstLarge

proc demote[Value; threshold: static[int]](
    table: var HybridSigilTable[Value, threshold]
) {.gcsafe, raises: [].} =
  case table.kind
  of hstSmall:
    return
  of hstLarge:
    discard

  if not useSmallStorage[threshold](table.large.len):
    return

  var small: seq[HybridSigilTableEntry[Value]]
  for key, values in table.large:
    if values.len == 0:
      continue
    let insertAt = lowerBoundEntry(small, key)
    small.insert(HybridSigilTableEntry[Value](
      key: key,
      values: values,
    ), insertAt)
  table.large = default(Table[SigilName, seq[Value]])
  table.small = small
  table.kind = hstSmall

func len*[Value; threshold: static[int]](
    table: HybridSigilTable[Value, threshold]
): int {.inline.} =
  table.valueCount

func keyCount*[Value; threshold: static[int]](
    table: HybridSigilTable[Value, threshold]
): int {.inline.} =
  case table.kind
  of hstSmall:
    table.small.len
  of hstLarge:
    table.large.len

proc clear*[Value; threshold: static[int]](
    table: var HybridSigilTable[Value, threshold]
) {.gcsafe, raises: [].} =
  table.valueCount = 0
  table.kind = hstSmall
  table.small.setLen(0)
  table.large = default(Table[SigilName, seq[Value]])

proc setLen*[Value; threshold: static[int]](
    table: var HybridSigilTable[Value, threshold], newLen: Natural
) {.gcsafe, raises: [].} =
  doAssert newLen == 0, "HybridSigilTable only supports setLen(0)"
  table.clear()

proc containsKey*[Value; threshold: static[int]](
    table: HybridSigilTable[Value, threshold], key: SigilName
): bool {.inline, gcsafe, raises: [].} =
  case table.kind
  of hstSmall:
    entryIndex[Value, threshold](table.small, key) >= 0
  of hstLarge:
    key in table.large

proc valuesLen*[Value; threshold: static[int]](
    table: HybridSigilTable[Value, threshold], key: SigilName
): int {.gcsafe, raises: [].} =
  case table.kind
  of hstSmall:
    let idx = entryIndex[Value, threshold](table.small, key)
    if idx >= 0:
      table.small[idx].values.len
    else:
      0
  of hstLarge:
    table.large.withValue(key, bucket):
      result = bucket.len

proc valuesCopy*[Value; threshold: static[int]](
    table: HybridSigilTable[Value, threshold], key: SigilName
): seq[Value] {.inline, gcsafe, raises: [].} =
  case table.kind
  of hstSmall:
    let idx = entryIndex[Value, threshold](table.small, key)
    if idx >= 0:
      result = table.small[idx].values
  of hstLarge:
    table.large.withValue(key, bucket):
      result = bucket

proc topValue*[Value; threshold: static[int]](
    table: HybridSigilTable[Value, threshold], key: SigilName
): Value {.inline, gcsafe, raises: [].} =
  case table.kind
  of hstSmall:
    let idx = entryIndex[Value, threshold](table.small, key)
    if idx >= 0 and table.small[idx].values.len > 0:
      result = table.small[idx].values[^1]
  of hstLarge:
    table.large.withValue(key, bucket):
      if bucket.len > 0:
        result = bucket[^1]

iterator valuesForKey*[Value; threshold: static[int]](
    table: var HybridSigilTable[Value, threshold], key: SigilName
): var Value =
  case table.kind
  of hstSmall:
    let idx = entryIndex[Value, threshold](table.small, key)
    if idx >= 0:
      for value in table.small[idx].values.mitems:
        yield value
  of hstLarge:
    table.large.withValue(key, bucket):
      for value in bucket[].mitems:
        yield value

iterator items*[Value; threshold: static[int]](
    table: HybridSigilTable[Value, threshold]
): HybridSigilTableItem[Value] =
  case table.kind
  of hstSmall:
    for entry in table.small:
      for value in entry.values:
        yield (key: entry.key, value: value)
  of hstLarge:
    var sorted: seq[HybridSigilTableEntry[Value]]
    for key, values in table.large:
      if values.len > 0:
        sorted.add(HybridSigilTableEntry[Value](key: key, values: values))
    sorted.sort do(a, b: HybridSigilTableEntry[Value]) -> int:
      compareSigilName(a.key, b.key)
    for entry in sorted:
      for value in entry.values:
        yield (key: entry.key, value: value)

proc `[]`*[Value; threshold: static[int]](
    table: HybridSigilTable[Value, threshold], index: int
): HybridSigilTableItem[Value] =
  var idx = index
  case table.kind
  of hstSmall:
    for entry in table.small:
      for value in entry.values:
        if idx == 0:
          return (key: entry.key, value: value)
        idx.dec()
  of hstLarge:
    var sorted: seq[HybridSigilTableEntry[Value]]
    for key, values in table.large:
      if values.len > 0:
        sorted.add(HybridSigilTableEntry[Value](key: key, values: values))
    sorted.sort do(a, b: HybridSigilTableEntry[Value]) -> int:
      compareSigilName(a.key, b.key)
    for entry in sorted:
      for value in entry.values:
        if idx == 0:
          return (key: entry.key, value: value)
        idx.dec()
  raise newException(IndexDefect, "HybridSigilTable index out of bounds")

proc containsValue*[Value; threshold: static[int]](
    table: HybridSigilTable[Value, threshold], key: SigilName,
    predicate: HybridMatchPredicate[Value],
): bool {.gcsafe, raises: [].} =
  case table.kind
  of hstSmall:
    let idx = entryIndex[Value, threshold](table.small, key)
    if idx < 0:
      return false
    for value in table.small[idx].values:
      if predicate(value):
        return true
  of hstLarge:
    table.large.withValue(key, bucket):
      for value in bucket:
        if predicate(value):
          return true

proc putValues*[Value; threshold: static[int]](
    table: var HybridSigilTable[Value, threshold], key: SigilName,
    values: sink seq[Value],
) {.gcsafe, raises: [].} =
  let newLen = values.len
  case table.kind
  of hstSmall:
    let idx = entryIndex[Value, threshold](table.small, key)
    if idx >= 0:
      let oldLen = table.small[idx].values.len
      if newLen == 0:
        table.small.delete(idx)
      else:
        table.small[idx].values = values
      table.valueCount += newLen - oldLen
    elif newLen > 0:
      let insertAt = lowerBoundEntry(table.small, key)
      table.small.insert(HybridSigilTableEntry[Value](
        key: key,
        values: values,
      ), insertAt)
      table.valueCount += newLen
      table.promote()
  of hstLarge:
    var matched = false
    var removeEntry = false
    table.large.withValue(key, bucket):
      matched = true
      let oldLen = bucket[].len
      if newLen == 0:
        removeEntry = true
      else:
        bucket[] = values
      table.valueCount += newLen - oldLen
    if removeEntry:
      table.large.del(key)
      table.demote()
    elif not matched and newLen > 0:
      table.large[key] = values
      table.valueCount += newLen

proc removeKey*[Value; threshold: static[int]](
    table: var HybridSigilTable[Value, threshold], key: SigilName
): seq[Value] {.gcsafe, raises: [].} =
  case table.kind
  of hstSmall:
    let idx = entryIndex[Value, threshold](table.small, key)
    if idx >= 0:
      result = table.small[idx].values
      table.valueCount -= result.len
      table.small.delete(idx)
  of hstLarge:
    var found = false
    table.large.withValue(key, bucket):
      result = bucket[]
      found = true
    if found:
      table.valueCount -= result.len
      table.large.del(key)
      table.demote()

proc addValue*[Value; threshold: static[int]](
    table: var HybridSigilTable[Value, threshold], key: SigilName, value: Value
): int {.gcsafe, raises: [].} =
  case table.kind
  of hstSmall:
    let idx = entryIndex[Value, threshold](table.small, key)
    if idx >= 0:
      result = table.small[idx].values.len
      table.small[idx].values.add value
    else:
      let insertAt = lowerBoundEntry(table.small, key)
      table.small.insert(HybridSigilTableEntry[Value](
        key: key,
        values: @[value],
      ), insertAt)
      table.promote()
  of hstLarge:
    table.large.withValue(key, bucket):
      result = bucket[].len
      bucket[].add value
    do:
      table.large[key] = @[value]
  table.valueCount.inc()

proc popValueStack*[Value; threshold: static[int]](
    table: var HybridSigilTable[Value, threshold], key: SigilName, depth: int
): bool {.gcsafe, raises: [].} =
  case table.kind
  of hstSmall:
    let idx = entryIndex[Value, threshold](table.small, key)
    if idx < 0:
      return false
    if table.small[idx].values.len != depth + 1:
      return false
    table.small[idx].values.setLen(depth)
    table.valueCount.dec()
    if table.small[idx].values.len == 0:
      table.small.delete(idx)
    result = true
  of hstLarge:
    var removeStack = false
    table.large.withValue(key, bucket):
      if bucket[].len != depth + 1:
        return false
      bucket[].setLen(depth)
      table.valueCount.dec()
      removeStack = bucket[].len == 0
      result = true
    do:
      return false
    if removeStack:
      table.large.del(key)
      table.demote()

proc removeMatchingValues[Value](
    values: var seq[Value], predicate: HybridRemovePredicate[Value]
): tuple[found, deleted: int] {.gcsafe, raises: [].} =
  var idx = values.len
  while idx > 0:
    idx.dec()
    case predicate(values[idx])
    of hraKeep:
      discard
    of hraFound:
      result.found.inc()
    of hraDelete:
      result.found.inc()
      result.deleted.inc()
      values.delete(idx)

proc removeValuesForKey*[Value; threshold: static[int]](
    table: var HybridSigilTable[Value, threshold], key: SigilName,
    predicate: HybridRemovePredicate[Value],
): tuple[found, deleted: int] {.gcsafe, raises: [].} =
  case table.kind
  of hstSmall:
    let idx = entryIndex[Value, threshold](table.small, key)
    if idx < 0:
      return
    result = removeMatchingValues(table.small[idx].values, predicate)
    table.valueCount -= result.deleted
    if table.small[idx].values.len == 0:
      table.small.delete(idx)
  of hstLarge:
    var removeEntry = false
    table.large.withValue(key, bucket):
      result = removeMatchingValues(bucket[], predicate)
      table.valueCount -= result.deleted
      removeEntry = bucket[].len == 0
    do:
      return
    if removeEntry:
      table.large.del(key)
      table.demote()

proc removeValues*[Value; threshold: static[int]](
    table: var HybridSigilTable[Value, threshold],
    predicate: HybridRemovePredicate[Value],
): int {.gcsafe, raises: [].} =
  case table.kind
  of hstSmall:
    var entryIdx = table.small.len
    while entryIdx > 0:
      entryIdx.dec()
      let removed = removeMatchingValues(table.small[entryIdx].values, predicate)
      result += removed.deleted
      table.valueCount -= removed.deleted
      if table.small[entryIdx].values.len == 0:
        table.small.delete(entryIdx)
  of hstLarge:
    var emptyKeys: seq[SigilName]
    for key, values in table.large.mpairs:
      let removed = removeMatchingValues(values, predicate)
      result += removed.deleted
      table.valueCount -= removed.deleted
      if values.len == 0:
        emptyKeys.add key
    for key in emptyKeys:
      table.large.del(key)
    if emptyKeys.len > 0:
      table.demote()
