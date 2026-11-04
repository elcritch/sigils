import std/[strutils, unittest]
import sigils/svariant
import variantTypesA as typesA
import variantTypesB as typesB

type
  IntAlias = int
  DistinctInt = distinct int
  Callback = proc(value: int): int {.closure.}

static:
  doAssert getTypeId(int) == getTypeId(IntAlias)
  doAssert getTypeId(int) != getTypeId(DistinctInt)
  doAssert getTypeId(typesA.SameName) != getTypeId(typesB.SameName)
  doAssert getTypeId(seq[typesA.SameName]) != getTypeId(seq[typesB.SameName])
  doAssert getTypeId(Container[int]) != getTypeId(Container[string])
  doAssert getTypeId(array[2, int]) != getTypeId(array[3, int])
  doAssert getTypeId(proc(a: int): int) == getTypeId(proc(b: int): int)
  doAssert getTypeId(int) != 0

proc addFive(value: int): int {.nimcall, gcsafe, noSideEffect.} = value + 5

proc capturedCallback(offset: int): Callback =
  result = proc(value: int): int = value + offset

suite "Sigils-owned Variant":
  test "empty and consumed variants reject reads":
    let empty = newVariant()
    check empty.isEmpty
    check not empty.ofType(int)
    expect Exception:
      discard empty.get(int)
    var packed = newOwnedVariant(@[1, 2, 3])
    check packed.takeVariant(seq[int]) == @[1, 2, 3]
    check packed.isEmpty
    expect Exception:
      discard packed.get(seq[int])
    expect Exception:
      discard packed.takeVariant(seq[int])

  test "wrong types fail without changing the value":
    let packed = newVariant(42)
    expect Exception:
      discard packed.get(string)
    expect Exception:
      discard packed.takeVariant(string)
    check packed.get(int) == 42

  test "debug type names are opt-in":
    try:
      discard newVariant().get(seq[int])
      check false
    except Exception as error:
      check "nil" in error.msg
      when defined(variantDebugTypes):
        check "Expected type: seq[int]" in error.msg
      else:
        check "seq[int]" notin error.msg

  test "managed get results are independent value copies":
    let packed = newVariant(@[1, 2, 3])
    var copy = packed.get(seq[int])
    copy[0] = 99
    check packed.get(seq[int]) == @[1, 2, 3]

  test "sibling modules agree on primitive and generic identities":
    check integerIdA() == integerIdB()
    check primitiveIdsA() == primitiveIdsB()
    check readIntegerB(boxedIntegerA()) == 42
    check readContainerB(boxedContainerA()) == 17

  test "nominal types with identical names stay distinct":
    let packed = newVariant(typesA.SameName(value: 12))
    check packed.ofType(typesA.SameName)
    check not packed.ofType(typesB.SameName)
    expect Exception:
      discard packed.get(typesB.SameName)

  test "procedure conversions retain calling conventions and captures":
    let plain = newVariant(addFive)
    check plain.ofType(Callback)
    check plain.get(Callback)(7) == 12
    let captured = newVariant(capturedCallback(9))
    check captured.get(Callback)(7) == 16
    check not captured.ofType(proc(value: int): int {.nimcall.})
    expect Exception:
      discard captured.get(proc(value: int): int {.nimcall.})

  test "variantMatch extracts values and handles empty":
    let packed = newVariant(@[1, 2, 3])
    var found = false
    variantMatch case packed as value
    of int:
      check false
    of seq[int]:
      check value == @[1, 2, 3]
      found = true
    else:
      check false
    check found
    variantMatch case newVariant()
    of int as number:
      check false
    else:
      discard

  test "variantMatch evaluates its input only once":
    var calls = 0
    proc makeValue(): Variant =
      inc calls
      newVariant(calls)
    variantMatch case makeValue()
    of int as number:
      check number == 1
    else:
      check false
    check calls == 1
