import std/[typetraits, unittest]

import sigils/[agents, cloneutils]

type
  UserId = distinct string

  RefPayload = ref object
    name: string
    values: seq[int]

  DefaultCloneAgent = ref object of Agent

  CloneableAgent = ref object of Agent
    value: RefPayload

  AgentEnvelope[T] = object
    agent: T

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

var sharedCloneCalls = 0

proc clone(value: SharedPayload): SharedPayload {.gcsafe.} =
  ## This value intentionally shares its reference when its parent is cloned.
  sharedCloneCalls.inc()
  value

proc clone(value: CloneableAgent): CloneableAgent {.gcsafe.} =
  if not value.isNil:
    result = CloneableAgent(value: value.value.clone())

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

  test "agents reject implicit deep clones":
    let source = DefaultCloneAgent()

    expect AgentCloneDefect:
      discard source.clone()

  test "nil agents clone to nil":
    let source: DefaultCloneAgent = nil

    check source.clone().isNil

  test "RC delivery retains agent identity":
    let source = DefaultCloneAgent()
    let payload = AgentEnvelope[DefaultCloneAgent](agent: source)
    let copied = payload.cloneForDelivery(CloneMode.Rc)

    check copied.agent == source

  test "deep delivery rejects agents without a clone overload":
    let source = DefaultCloneAgent()
    let payload = AgentEnvelope[DefaultCloneAgent](agent: source)

    when defined(gcAtomicArc):
      let copied = payload.cloneForDelivery(CloneMode.Deep)
      check copied.agent == source
    else:
      expect AgentCloneDefect:
        discard payload.cloneForDelivery(CloneMode.Deep)

  test "explicit agent clone overloads apply recursively":
    let source = CloneableAgent(
      value: RefPayload(name: "agent", values: @[1, 2, 3])
    )
    let payload = AgentEnvelope[CloneableAgent](agent: source)
    var copied = payload.clone()

    check copied.agent != source
    check copied.agent.value != source.value
    copied.agent.value.name[0] = 'A'
    copied.agent.value.values[0] = 9

    check source.value.name == "agent"
    check source.value.values == @[1, 2, 3]
    check copied.agent.value.name == "Agent"
    check copied.agent.value.values == @[9, 2, 3]

  test "custom clone overloads apply recursively":
    sharedCloneCalls = 0
    let source = CloneEnvelope(
      shared: SharedPayload(value: RefPayload(name: "shared", values: @[1]))
    )
    let copied = source.clone()

    check sharedCloneCalls == 1
    check copied.shared.value == source.shared.value

  test "RC clone retains references and copies value containers":
    sharedCloneCalls = 0
    let source = CasePayload(
      requestId: UserId("request-rc"),
      kind: TextPayload,
      text: "alpha",
      metadata: RefPayload(name: "meta", values: @[1, 2]),
    )
    var copied = source.cloneRc()

    check sharedCloneCalls == 0
    check copied.metadata == source.metadata
    copied.text[0] = 'A'
    copied.metadata.name[0] = 'M'

    check source.text == "alpha"
    check source.metadata.name == "Meta"

  test "delivery cloning follows the memory manager":
    let source = RefPayload(name: "delivery", values: @[1])
    let copied = source.cloneForDelivery(CloneMode.Deep)

    when defined(gcAtomicArc):
      check copied == source
    else:
      check copied != source

  test "delivery cloning can explicitly retain references":
    let source = RefPayload(name: "delivery", values: @[1])
    let copied = source.cloneForDelivery(CloneMode.Rc)

    check copied == source

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
