import std/unittest
import sigils/[hybridTables, protocol]

suite "hybrid selector table":
  test "every key stays readable after promotion":
    var table: HybridSigilTable[int]
    for index in 0 ..< 32:
      table.putValues(toSigilName("largePayload" & $index), @[index + 1])

    for index in 0 ..< 32:
      let key = toSigilName("largePayload" & $index)
      check table.containsKey(key)
      check table.valuesLen(key) == 1
      check table.valuesCopy(key) == @[index + 1]
      check table.topValue(key) == index + 1

    let missing = toSigilName("missing")
    check not table.containsKey(missing)
    check table.valuesLen(missing) == 0
    check table.valuesCopy(missing).len == 0
    check table.topValue(missing) == 0
