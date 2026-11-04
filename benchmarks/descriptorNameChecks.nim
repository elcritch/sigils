## Ownership stress check for the experimental subclass descriptor control.
import descriptorNames

proc runtimeName(value: string): DescriptorName = initDescriptorName(value)

proc copyNames(source: ptr DescriptorName) {.thread.} =
  for index in 0 ..< 10_000:
    var first = source[]
    let second = first
    first = default(DescriptorName)
    doAssert $second == "shared descriptor"

block:
  var name = runtimeName("shared descriptor")
  `=copy`(name, name)
  var workers: array[4, Thread[ptr DescriptorName]]
  for worker in workers.mitems:
    createThread(worker, copyNames, addr name)
  copyNames(addr name)
  joinThreads(workers)
  doAssert $name == "shared descriptor"
echo "descriptor ownership checks passed"
