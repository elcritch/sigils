import std/unittest

import sigils

type
  RefPayload = ref object
    text: string

  Emitter = ref object of Agent

  Receiver = ref object of Agent
    received: RefPayload

proc published(source: Emitter, payload: RefPayload) {.signal.}

proc receive(receiver: Receiver, payload: RefPayload) {.slot.} =
  receiver.received = payload

suite "packed signal ownership":
  test "single packed recipient receives the original payload":
    let
      source = Emitter()
      receiver = Receiver()
      packedSlot = Receiver.receive()
      payload = RefPayload(text: "single")

    connect(source, published, receiver, packedSlot)
    emit source.published(payload)

    check receiver.received == payload
    check receiver.received.text == "single"

  test "packed fanout follows the memory manager reference policy":
    let
      source = Emitter()
      first = Receiver()
      second = Receiver()
      packedSlot = Receiver.receive()
      payload = RefPayload(text: "fanout")

    connect(source, published, first, packedSlot)
    connect(source, published, second, packedSlot)
    emit source.published(payload)

    check not first.received.isNil
    check not second.received.isNil
    when defined(gcAtomicArc):
      check first.received == payload
      check second.received == payload

      first.received.text[0] = 'F'
      check second.received.text == "Fanout"
    else:
      check first.received != second.received
      check first.received == payload or second.received == payload

      first.received.text[0] = 'F'
      check second.received.text == "fanout"
