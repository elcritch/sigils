import std/[strutils, unittest]

import sigils/protocol

type ManagedPayload = tuple[requestId: int, text: string, depth: int]

type LifetimePayload = ref object
  id: int

type CustomPayload = object
  value: LifetimePayload

var destroyedPayloads = 0
var customCloneCalls = 0

proc `=destroy`(payload: typeof(LifetimePayload()[])) =
  if payload.id != 0:
    destroyedPayloads.inc()

proc clone(payload: CustomPayload): CustomPayload {.gcsafe.} =
  customCloneCalls.inc()
  payload

suite "SVariant managed payload ownership":
  test "clone owns an independent managed payload":
    let
      firstText = repeat('a', 128)
      secondText = repeat('b', 128)
      first: ManagedPayload = (requestId: 1, text: firstText, depth: 4)
      second: ManagedPayload = (requestId: 2, text: secondText, depth: 8)
    var source = rpcPack(first)
    let
      queued = source.clone()

    source = rpcPack(second)

    check source.payload.get(ManagedPayload) == second
    check queued.payload.get(ManagedPayload) == first

  test "typed variant destroys its managed payload":
    destroyedPayloads = 0
    block:
      var payload = LifetimePayload(id: 1)
      let packed = rpcPack(move(payload))

      check payload.isNil
      check packed.payload.get(LifetimePayload).id == 1

    check destroyedPayloads == 1

  test "typed variant uses a custom clone overload":
    customCloneCalls = 0
    let
      payload = CustomPayload(value: LifetimePayload(id: 2))
      packed = rpcPack(payload)
      copied = packed.clone()

    check customCloneCalls == 1
    check copied.payload.get(CustomPayload).value == payload.value
