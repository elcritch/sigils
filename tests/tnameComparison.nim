import std/[strutils, unittest]
import sigils/protocol

static:
  doAssert compareSigilName(toSigilName("a"), toSigilName("aa")) < 0
  doAssert compareSigilName(toSigilName("same"), toSigilName("same")) == 0

suite "signal name comparison":
  test "ordering agrees with strings for empty, prefix, and byte values":
    let values = @["", "a", "aa", "ab", "a\0b", "a\0c", "\0", "b",
      "\x7f", "\x80", "\xff", "καλημέρα"]
    for left in values:
      for right in values:
        when sigilsSharedNamesEnabled:
          if '\0' in left or '\0' in right:
            continue
        let actual = compareSigilName(toSigilName(left), toSigilName(right))
        let expected = cmp(left, right)
        check (actual < 0) == (expected < 0)
        check (actual == 0) == (expected == 0)
        check (actual > 0) == (expected > 0)

  when defined(nimAllocStats):
    test "runtime comparisons allocate no temporary strings":
      let left = toSigilName("a-prefix-left")
      let right = toSigilName("a-prefix-right")
      var score = 0
      let before = getAllocStats()
      for index in 0 ..< 10_000:
        if compareSigilName(left, right) < 0:
          inc score
      let delta = getAllocStats() - before
      check score == 10_000
      check $delta == "(allocCount: 0, deallocCount: 0)"
