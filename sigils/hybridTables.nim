import std/[algorithm, tables]

import protocol

const sigilsHybridTableThreshold* {.intdefine.} = 16

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

  HybridSigilTable*[Value] = object
    ## Sigil-keyed multimap that keeps a sorted seq for small key counts and
    ## promotes to a hash table once selector/subscription lookups are larger.
    case kind*: HybridSigilTableKind
    of hstSmall:
      small: seq[HybridSigilTableEntry[Value]]
    of hstLarge:
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

func useSmallStorage(keyCount: int): bool {.inline.} =
  sigilsHybridTableThreshold > 0 and keyCount < sigilsHybridTableThreshold

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

proc entryIndex[Value](
    entries: openArray[HybridSigilTableEntry[Value]], key: SigilName
): int {.inline, gcsafe, raises: [].} =
  if useSmallStorage(entries.len):
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

proc promote[Value](table: var HybridSigilTable[Value]) {.gcsafe,
    raises: [].} =
  case table.kind
  of hstLarge:
    return
  of hstSmall:
    discard

  if useSmallStorage(table.small.len):
    return

  var large: Table[SigilName, seq[Value]]
  for item in table.small:
    large[item.key] = item.values
  table = HybridSigilTable[Value](kind: hstLarge, large: large)

proc demote[Value](table: var HybridSigilTable[Value]) {.gcsafe,
    raises: [].} =
  case table.kind
  of hstSmall:
    return
  of hstLarge:
    discard

  if not useSmallStorage(table.large.len):
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
  table = HybridSigilTable[Value](kind: hstSmall, small: small)

proc len*[Value](table: HybridSigilTable[Value]): int {.inline, gcsafe,
    raises: [].} =
  case table.kind
  of hstSmall:
    for entry in table.small:
      result += entry.values.len
  of hstLarge:
    for _, values in table.large:
      result += values.len

func keyCount*[Value](table: HybridSigilTable[Value]): int {.inline.} =
  case table.kind
  of hstSmall:
    table.small.len
  of hstLarge:
    table.large.len

proc clear*[Value](table: var HybridSigilTable[Value]) {.gcsafe, raises: [].} =
  table = HybridSigilTable[Value](kind: hstSmall)

proc setLen*[Value](
    table: var HybridSigilTable[Value], newLen: Natural
) {.gcsafe, raises: [].} =
  doAssert newLen == 0, "HybridSigilTable only supports setLen(0)"
  table.clear()

proc containsKey*[Value](
    table: HybridSigilTable[Value], key: SigilName
): bool {.inline, gcsafe, raises: [].} =
  case table.kind
  of hstSmall:
    entryIndex(table.small, key) >= 0
  of hstLarge:
    key in table.large

proc valuesLen*[Value](
    table: HybridSigilTable[Value], key: SigilName
): int {.gcsafe, raises: [].} =
  case table.kind
  of hstSmall:
    let idx = entryIndex(table.small, key)
    if idx >= 0:
      table.small[idx].values.len
    else:
      0
  of hstLarge:
    table.large.withValue(key, bucket):
      result = bucket.len

proc valuesCopy*[Value](
    table: HybridSigilTable[Value], key: SigilName
): seq[Value] {.inline, gcsafe, raises: [].} =
  case table.kind
  of hstSmall:
    let idx = entryIndex(table.small, key)
    if idx >= 0:
      result = table.small[idx].values
  of hstLarge:
    table.large.withValue(key, bucket):
      result = bucket

proc topValue*[Value](
    table: HybridSigilTable[Value], key: SigilName
): Value {.inline, gcsafe, raises: [].} =
  case table.kind
  of hstSmall:
    let idx = entryIndex(table.small, key)
    if idx >= 0 and table.small[idx].values.len > 0:
      result = table.small[idx].values[^1]
  of hstLarge:
    table.large.withValue(key, bucket):
      if bucket.len > 0:
        result = bucket[^1]

iterator valuesForKey*[Value](
    table: var HybridSigilTable[Value], key: SigilName
): var Value =
  case table.kind
  of hstSmall:
    let idx = entryIndex(table.small, key)
    if idx >= 0:
      for value in table.small[idx].values.mitems:
        yield value
  of hstLarge:
    table.large.withValue(key, bucket):
      for value in bucket[].mitems:
        yield value

iterator items*[Value](
    table: HybridSigilTable[Value]
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

proc `[]`*[Value](
    table: HybridSigilTable[Value], index: int
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

proc containsValue*[Value](
    table: HybridSigilTable[Value], key: SigilName,
    predicate: HybridMatchPredicate[Value],
): bool {.gcsafe, raises: [].} =
  case table.kind
  of hstSmall:
    let idx = entryIndex(table.small, key)
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

proc putValues*[Value](
    table: var HybridSigilTable[Value], key: SigilName, values: sink seq[Value],
) {.gcsafe, raises: [].} =
  let newLen = values.len
  case table.kind
  of hstSmall:
    let idx = entryIndex(table.small, key)
    if idx >= 0:
      if newLen == 0:
        table.small.delete(idx)
      else:
        table.small[idx].values = values
    elif newLen > 0:
      let insertAt = lowerBoundEntry(table.small, key)
      table.small.insert(HybridSigilTableEntry[Value](
        key: key,
        values: values,
      ), insertAt)
      table.promote()
  of hstLarge:
    var matched = false
    var removeEntry = false
    table.large.withValue(key, bucket):
      matched = true
      if newLen == 0:
        removeEntry = true
      else:
        bucket[] = values
    if removeEntry:
      table.large.del(key)
      table.demote()
    elif not matched and newLen > 0:
      table.large[key] = values

proc removeKey*[Value](
    table: var HybridSigilTable[Value], key: SigilName
): seq[Value] {.gcsafe, raises: [].} =
  case table.kind
  of hstSmall:
    let idx = entryIndex(table.small, key)
    if idx >= 0:
      result = table.small[idx].values
      table.small.delete(idx)
  of hstLarge:
    var found = false
    table.large.withValue(key, bucket):
      result = bucket[]
      found = true
    if found:
      table.large.del(key)
      table.demote()

proc addValue*[Value](
    table: var HybridSigilTable[Value], key: SigilName, value: Value
): int {.gcsafe, raises: [].} =
  case table.kind
  of hstSmall:
    let idx = entryIndex(table.small, key)
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

proc popValueStack*[Value](
    table: var HybridSigilTable[Value], key: SigilName, depth: int
): bool {.gcsafe, raises: [].} =
  case table.kind
  of hstSmall:
    let idx = entryIndex(table.small, key)
    if idx < 0:
      return false
    if table.small[idx].values.len != depth + 1:
      return false
    table.small[idx].values.setLen(depth)
    if table.small[idx].values.len == 0:
      table.small.delete(idx)
    result = true
  of hstLarge:
    var removeStack = false
    table.large.withValue(key, bucket):
      if bucket[].len != depth + 1:
        return false
      bucket[].setLen(depth)
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

proc removeValuesForKey*[Value](
    table: var HybridSigilTable[Value], key: SigilName,
    predicate: HybridRemovePredicate[Value],
): tuple[found, deleted: int] {.gcsafe, raises: [].} =
  case table.kind
  of hstSmall:
    let idx = entryIndex(table.small, key)
    if idx < 0:
      return
    result = removeMatchingValues(table.small[idx].values, predicate)
    if table.small[idx].values.len == 0:
      table.small.delete(idx)
  of hstLarge:
    var removeEntry = false
    table.large.withValue(key, bucket):
      result = removeMatchingValues(bucket[], predicate)
      removeEntry = bucket[].len == 0
    do:
      return
    if removeEntry:
      table.large.del(key)
      table.demote()

proc removeValues*[Value](
    table: var HybridSigilTable[Value], predicate: HybridRemovePredicate[Value],
): int {.gcsafe, raises: [].} =
  case table.kind
  of hstSmall:
    var entryIdx = table.small.len
    while entryIdx > 0:
      entryIdx.dec()
      let removed = removeMatchingValues(table.small[entryIdx].values, predicate)
      result += removed.deleted
      if table.small[entryIdx].values.len == 0:
        table.small.delete(entryIdx)
  of hstLarge:
    var emptyKeys: seq[SigilName]
    for key, values in table.large.mpairs:
      let removed = removeMatchingValues(values, predicate)
      result += removed.deleted
      if values.len == 0:
        emptyKeys.add key
    for key in emptyKeys:
      table.large.del(key)
    if emptyKeys.len > 0:
      table.demote()
