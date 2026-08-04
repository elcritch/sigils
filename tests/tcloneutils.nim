import std/[typetraits, unittest]

import sigils/cloneutils

type
  UserId = distinct string

  RefPayload = ref object
    name: string
    values: seq[int]

  SharedPayload = object
    value: RefPayload

  CloneEnvelope = object
    shared: SharedPayload

  PayloadKind = enum
    TextPayload
    NumberPayload

  CasePayload = object
    requestId: UserId
    case kind: PayloadKind
    of TextPayload:
      text: string
      metadata: RefPayload
    of NumberPayload:
      numbers: seq[int]

proc clone(value: SharedPayload): SharedPayload {.gcsafe.} =
  ## This value intentionally shares its reference when its parent is cloned.
  value

suite "recursive clone":
  test "strings and sequences preserve value semantics":
    let source = (text: "alpha", values: @[1, 2, 3])
    var copied = source.clone()

    copied.text[0] = 'A'
    copied.values[0] = 9

    check source == (text: "alpha", values: @[1, 2, 3])
    check copied == (text: "Alpha", values: @[9, 2, 3])

  test "references are cloned recursively":
    let source = RefPayload(name: "alpha", values: @[1, 2, 3])
    var copied = source.clone()

    check copied != source
    copied.name[0] = 'A'
    copied.values[0] = 9

    check source.name == "alpha"
    check source.values == @[1, 2, 3]
    check copied.name == "Alpha"
    check copied.values == @[9, 2, 3]

  test "custom clone overloads apply recursively":
    let source = CloneEnvelope(
      shared: SharedPayload(value: RefPayload(name: "shared", values: @[1]))
    )
    let copied = source.clone()

    check copied.shared.value == source.shared.value

  test "distinct values clone through their base type":
    let source = UserId("user-1")
    var copied = source.clone()

    distinctBase(copied)[0] = 'U'

    check distinctBase(source) == "user-1"
    check distinctBase(copied) == "User-1"

  test "arrays retain their declared index range":
    var source: array[2 .. 4, RefPayload]
    source[2] = RefPayload(name: "two", values: @[2])
    source[3] = RefPayload(name: "three", values: @[3])
    source[4] = RefPayload(name: "four", values: @[4])
    let copied = source.clone()

    for index in low(source) .. high(source):
      check copied[index] != source[index]
      check copied[index].name == source[index].name

  test "case object text branch preserves its active fields":
    let source = CasePayload(
      requestId: UserId("request-1"),
      kind: TextPayload,
      text: "alpha",
      metadata: RefPayload(name: "meta", values: @[1, 2]),
    )
    var copied = source.clone()

    check copied.kind == TextPayload
    check copied.metadata != source.metadata
    copied.text[0] = 'A'
    copied.metadata.name[0] = 'M'
    copied.metadata.values[0] = 9

    check source.text == "alpha"
    check source.metadata.name == "meta"
    check source.metadata.values == @[1, 2]
    check copied.text == "Alpha"
    check copied.metadata.name == "Meta"
    check copied.metadata.values == @[9, 2]

  test "case object number branch preserves its active fields":
    let source = CasePayload(
      requestId: UserId("request-2"),
      kind: NumberPayload,
      numbers: @[1, 2, 3],
    )
    var copied = source.clone()

    check copied.kind == NumberPayload
    copied.numbers[0] = 9

    check source.numbers == @[1, 2, 3]
    check copied.numbers == @[9, 2, 3]
