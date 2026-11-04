import std/[hashes, strutils, tables, unittest]
import sigils/[sharednames, cloneutils]

const literal = initSharedName("literal")

proc runtimeName(value: string): SharedName {.noinline.} = initSharedName(value)

proc copyNames(source: ptr SharedName) {.thread.} =
  for index in 0 ..< 10_000:
    var copy = source[]
    var second = copy
    doAssert $second == "shared across threads"
    copy = default(SharedName)
    doAssert second.len == 21

suite "immutable shared names":
  test "literal and runtime storage compare by bytes":
    let dynamic = runtimeName("literal")
    check dynamic == literal
    check dynamic == "literal"
    check "literal" == dynamic
    check dynamic != "different"
    check hash(dynamic) == hash(literal)
    check cmp(dynamic, literal) == 0
    check default(SharedName) == initSharedName("")
    check hash(default(SharedName)) == hash(initSharedName(""))
    check cmp(initSharedName("a"), initSharedName("aa")) < 0
    check cmp(initSharedName("\xff"), initSharedName("\x7f")) > 0

  test "NUL is rejected and UTF-8 bytes retain their lengths":
    static:
      doAssert not compiles(initSharedName("a\0b"))
    expect ValueError:
      discard runtimeName("a\0b")
    check $runtimeName("καλημέρα") == "καλημέρα"

  test "runtime input is copied and name copies survive their source":
    var source = "runtime " & repeat('x', 100)
    var name = runtimeName(source)
    var copy = name
    source[0] = 'X'
    check ($copy)[0] == 'r'
    name = initSharedName("replacement")
    check copy.len == 108
    `=copy`(copy, copy)
    check ($copy)[0] == 'r'
    let moved = move(copy)
    check copy.len == 0
    check moved.len == 108

  test "table keys and nested delivery clones retain ownership":
    var name = runtimeName("runtime key")
    var table = initTable[SharedName, int]()
    table[name] = 42
    let original = (names: @[name, literal], )
    let copied = clone(original)
    name = default(SharedName)
    check table[runtimeName("runtime key")] == 42
    check copied.names[0] == original.names[0]
    check $copied.names[0] == "runtime key"

  test "dynamic owners can be retained and released concurrently":
    var name = runtimeName("shared across threads")
    var workers: array[4, Thread[ptr SharedName]]
    for worker in workers.mitems:
      createThread(worker, copyNames, addr name)
    copyNames(addr name)
    joinThreads(workers)
    check $name == "shared across threads"

  when defined(sigilsNameMetrics):
    test "static names allocate nothing and shared copies allocate once":
      let before = sharedNameMetrics()
      block:
        var copies: seq[SharedName]
        for index in 0 ..< 100:
          copies.add literal
        check sharedNameMetrics().allocations == before.allocations
        let owned = runtimeName("counted allocation")
        for index in 0 ..< 100:
          copies.add owned
        check sharedNameMetrics().allocations == before.allocations + 1
        check copies.len == 200
      check sharedNameMetrics().releases == before.releases + 1
