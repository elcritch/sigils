## Shared FIFO storage for scheduler messages. Ordinary sends never wait for
## capacity; trySend provides an explicit bounded admission policy.
import std/[deques, isolation, locks]
import threading/smartptrs
export smartptrs.isNil

type
  MailboxData[T] = object
    lock: Lock
    available: Cond
    items: Deque[T]
    capacity: int
  Mailbox*[T] = object
    data: SharedPtr[MailboxData[T]]

proc `=destroy`[T](data: var MailboxData[T]) =
  `=destroy`(data.items)
  deinitCond(data.available)
  deinitLock(data.lock)

proc newMailbox*[T](capacity = 1_000): Mailbox[T] =
  doAssert capacity > 0
  result.data = newSharedPtr(unsafeIsolate(MailboxData[T](
    items: initDeque[T](), capacity: capacity)))
  initLock(result.data[].lock)
  initCond(result.data[].available)

proc send*[T](mailbox: Mailbox[T], value: sink Isolated[T]) =
  withLock mailbox.data[].lock:
    mailbox.data[].items.addLast(extract(value))
    signal(mailbox.data[].available)

proc trySend*[T](mailbox: Mailbox[T], value: sink Isolated[T]): bool =
  withLock mailbox.data[].lock:
    if mailbox.data[].items.len < mailbox.data[].capacity:
      mailbox.data[].items.addLast(extract(value))
      signal(mailbox.data[].available)
      result = true

proc tryRecv*[T](mailbox: Mailbox[T], value: var T): bool =
  withLock mailbox.data[].lock:
    if mailbox.data[].items.len > 0:
      value = mailbox.data[].items.popFirst()
      result = true

proc recv*[T](mailbox: Mailbox[T]): T =
  withLock mailbox.data[].lock:
    while mailbox.data[].items.len == 0:
      wait(mailbox.data[].available, mailbox.data[].lock)
    result = mailbox.data[].items.popFirst()

proc peek*[T](mailbox: Mailbox[T]): int =
  withLock mailbox.data[].lock:
    result = mailbox.data[].items.len
