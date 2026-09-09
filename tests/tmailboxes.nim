import std/[isolation, unittest]
import threading/atomics
import sigils/mailboxes

var destroyed: Atomic[int]

type Payload = object
  id: int

proc `=destroy`(payload: Payload) =
  if payload.id != 0:
    discard destroyed.fetchAdd(1)

suite "scheduler mailboxes":
  test "ordinary sends grow without waiting and preserve FIFO":
    let mailbox = newMailbox[int](1)
    for value in 1 .. 100:
      mailbox.send(isolate(value))
    check mailbox.peek() == 100
    for value in 1 .. 100:
      check mailbox.recv() == value
    check mailbox.peek() == 0

  test "trySend enforces the configured admission limit":
    let mailbox = newMailbox[int](1)
    check mailbox.trySend(isolate(1))
    check not mailbox.trySend(isolate(2))
    check mailbox.recv() == 1
    check mailbox.trySend(isolate(3))
    check mailbox.recv() == 3

  test "the final shared owner destroys unread payloads":
    destroyed.store(0)
    var retained: Mailbox[Payload]
    block:
      let mailbox = newMailbox[Payload](1)
      retained = mailbox
      mailbox.send(isolate(Payload(id: 1)))
      mailbox.send(isolate(Payload(id: 2)))
    check destroyed.load() == 0
    reset(retained)
    check destroyed.load() == 2
