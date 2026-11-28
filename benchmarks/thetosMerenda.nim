## Compile from an Atlas-configured Merenda checkout. See benchmarks/README.md.
import std/[monotimes, times]
import merenda/nimkit/view/views
import sigils/features

const
  viewCount {.intdefine.} = 20_000
  lookupPasses {.intdefine.} = 100

proc run() =
  block warmup:
    let view = newView()
    doAssert view.tag == 0

  var views = newSeq[View](viewCount)
  let before = getOccupiedMem()
  let started = getMonoTime()
  for view in views.mitems:
    view = newView()
  let creationNs = (getMonoTime() - started).inNanoseconds
  let retainedBytes = getOccupiedMem() - before
  doAssert retainedBytes > 0, "compile with Nim's allocator (-u:useMalloc)"

  for i, view in views:
    view.tag = i
  let lookupStart = getMonoTime()
  var checksum: int64
  for _ in 0..<lookupPasses:
    for view in views:
      checksum += view.tag
      if view.hidden:
        inc checksum
  let lookupNs = (getMonoTime() - lookupStart).inNanoseconds
  doAssert checksum == lookupPasses.int64 * viewCount * (viewCount - 1) div 2
  echo "thetos=", sigilsThetosEnabled,
    " views=", viewCount,
    " creation_ns_per_view=", creationNs.float / viewCount.float,
    " retained_bytes_per_view=", retainedBytes.float / viewCount.float,
    " dispatch_ns_per_call=", lookupNs.float / (2 * lookupPasses *
        viewCount).float

run()
