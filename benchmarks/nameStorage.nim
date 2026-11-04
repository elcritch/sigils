## Compare storage backends with -d:nameBackend=stack|direct|shared|string|class.
## Run separately with -d:nimAllocStats for allocation counts, without it for time.
import std/[hashes, macros, monotimes, strutils, tables, times]

const
  nameBackend {.strdefine.} = "stack"
  nameOperations {.intdefine.} = 200_000
  nameCopyRounds {.intdefine.} = 1_000
  poolSize = 512

when nameBackend == "shared":
  import sigils/sharednames
  type Name = SharedName
  template makeName(value: untyped): Name = initSharedName(value)
elif nameBackend == "class":
  import classNames
  type Name = ClassName
  template makeName(value: untyped): Name = initClassName(value)
elif nameBackend == "string":
  type Name = string
  proc makeName(value: static string): Name = value
  proc makeName(value: string): Name = value
else:
  import stack_strings
  type Name = StackString[48]
  template makeName(value: untyped): Name = toStackString(value, 48)

proc compareNames(a, b: Name): int =
  when nameBackend == "stack":
    cmp($a, $b)
  elif nameBackend == "direct":
    let common = min(a.len, b.len)
    if common > 0:
      result = cmpMem(unsafeAddr a.data[0], unsafeAddr b.data[0], common)
      if result != 0: return
    result = cmp(a.len, b.len)
  else:
    cmp(a, b)

macro literalNames(): untyped =
  result = nnkPrefix.newTree(ident"@", nnkBracket.newTree())
  for index in 0 ..< poolSize:
    result[1].add newCall(ident"makeName", newLit("selector_" & align($index, 4, '0')))

proc copyNames(source: seq[Name], target: var seq[Name]) {.noinline.} =
  for index in 0 ..< source.len:
    target[index] = source[index]

template measure(label: string, body: untyped) =
  block:
    let allocationsBefore = getAllocStats()
    let start = getMonoTime()
    body
    let elapsed = (getMonoTime() - start).inMicroseconds
    let allocations = getAllocStats() - allocationsBefore
    when defined(nimAllocStats):
      echo label, " us=", elapsed, " allocations=", allocations
    else:
      echo label, " us=", elapsed

proc run() =
  when defined(nimAllocStats):
    echo "startup_allocations=", getAllocStats()
  echo "backend=", nameBackend, " nameBytes=", sizeof(Name),
    " operations=", nameOperations, " copyRounds=", nameCopyRounds
  let literals = literalNames()
  var strings = newSeq[string](poolSize)
  var dynamic = newSeq[Name](poolSize)
  var target = newSeq[Name](poolSize)
  for index in 0 ..< poolSize:
    strings[index] = "selector_" & align($index, 4, '0')
    dynamic[index] = makeName(strings[index])
    doAssert literals[index] == dynamic[index]
    doAssert hash(literals[index]) == hash(dynamic[index])

  measure("static_construct"):
    for index in 0 ..< nameOperations:
      target[index mod poolSize] = makeName("selector_0000")
  doAssert $target[0] == "selector_0000"

  measure("dynamic_construct"):
    for index in 0 ..< nameOperations:
      target[index mod poolSize] = makeName(strings[index mod poolSize])
  doAssert target[0] == dynamic[0]

  measure("static_copy"):
    for index in 0 ..< nameCopyRounds:
      copyNames(literals, target)
  doAssert target[^1] == literals[^1]

  measure("dynamic_copy"):
    for index in 0 ..< nameCopyRounds:
      copyNames(dynamic, target)
  doAssert target[^1] == dynamic[^1]

  var score = 0
  measure("compare"):
    for index in 0 ..< nameOperations:
      if compareNames(dynamic[index mod poolSize], dynamic[(index * 31 +
          7) mod poolSize]) < 0:
        inc score
  doAssert score > 0

  var lookup = initTable[Name, int]()
  for index, name in literals:
    lookup[name] = index
  var checksum = 0
  measure("lookup"):
    for index in 0 ..< nameOperations:
      checksum += lookup[dynamic[index mod poolSize]]
  var expected = 0
  for index in 0 ..< nameOperations:
    expected += index mod poolSize
  doAssert checksum == expected
  echo "checksum=", checksum, " compareScore=", score

run()
