import std/[os, strutils, unittest]
import threading/atomics

import sigils
import sigils/threads

type
  CloneProbe = distinct int

  PayloadKind = enum
    TextPayload
    NumberPayload

  ManagedPayload = object
    id: int
    probe: CloneProbe
    case kind: PayloadKind
    of TextPayload:
      text: string
      tags: seq[string]
    of NumberPayload:
      numbers: seq[int]

  PayloadSource = ref object of AgentActor

  PayloadReceiver = ref object of AgentActor
    receiverId: int

var
  cloneCalls: Atomic[int]
  invalidPayloads: Atomic[int]
  receivedPayloads: array[2, Atomic[int]]

proc clone(value: CloneProbe): CloneProbe {.gcsafe.} =
  cloneCalls.atomicInc()
  value

proc payloadChanged(source: PayloadSource, payload: ManagedPayload) {.signal.}

proc valid(payload: ManagedPayload): bool =
  if int(payload.probe) != payload.id:
    return false

  case payload.kind
  of TextPayload:
    let letter = char(ord('a') + payload.id mod 26)
    payload.text == repeat(letter, 128) and
      payload.tags == @["item-" & $payload.id, "next-" & $(payload.id + 1)]
  of NumberPayload:
    payload.numbers == @[payload.id, payload.id + 1, payload.id + 2]

proc receivePayload(receiver: PayloadReceiver,
    payload: ManagedPayload) {.slot.} =
  if not payload.valid():
    invalidPayloads.atomicInc()
  receivedPayloads[receiver.receiverId].atomicInc()

proc payload(id: int): ManagedPayload =
  if id mod 2 == 0:
    ManagedPayload(
      id: id,
      probe: CloneProbe(id),
      kind: TextPayload,
      text: repeat(char(ord('a') + id mod 26), 128),
      tags: @["item-" & $id, "next-" & $(id + 1)],
    )
  else:
    ManagedPayload(
      id: id,
      probe: CloneProbe(id),
      kind: NumberPayload,
      numbers: @[id, id + 1, id + 2],
    )

proc waitForReceived(receiverId, expected: int) =
  for _ in 1 .. 5_000:
    if receivedPayloads[receiverId].load() == expected:
      return
    os.sleep(1)

proc resetCounters() =
  cloneCalls.store(0)
  invalidPayloads.store(0)
  for received in receivedPayloads.mitems:
    received.store(0)

suite "typed variant thread ownership":
  test "single recipient moves managed case payloads without cloning":
    const MessageCount = 100
    resetCounters()
    let
      thread = newSigilThread()
      source = PayloadSource()
    var receiver = PayloadReceiver(receiverId: 0)
    let proxy = receiver.moveToThread(thread)

    thread.start()
    connectThreaded(source, payloadChanged, proxy, receivePayload)
    for id in 0 ..< MessageCount:
      emit source.payloadChanged(payload(id))

    check cloneCalls.load() == 0
    waitForReceived(0, MessageCount)
    check receivedPayloads[0].load() == MessageCount
    check invalidPayloads.load() == 0

    thread.setRunning(false)
    thread.join()

  test "fanout clones one owned case payload and moves the other":
    const MessageCount = 100
    resetCounters()
    let
      thread = newSigilThread()
      source = PayloadSource()
    var
      first = PayloadReceiver(receiverId: 0)
      second = PayloadReceiver(receiverId: 1)
    let
      firstProxy = first.moveToThread(thread)
      secondProxy = second.moveToThread(thread)

    thread.start()
    connectThreaded(source, payloadChanged, firstProxy, receivePayload)
    connectThreaded(source, payloadChanged, secondProxy, receivePayload)
    for id in 0 ..< MessageCount:
      emit source.payloadChanged(payload(id))

    check cloneCalls.load() == MessageCount
    waitForReceived(0, MessageCount)
    waitForReceived(1, MessageCount)
    check receivedPayloads[0].load() == MessageCount
    check receivedPayloads[1].load() == MessageCount
    check invalidPayloads.load() == 0

    thread.setRunning(false)
    thread.join()
