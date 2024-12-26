import std/isolation
import threading/channels

export isolation, channels

type
  SigilChan*[T] = object of RootObj
    ch*: Chan[T]
    fnTrySend*: proc (chan: SigilChan[T], msg: sink Isolated[T]): bool {.nimcall, gcsafe.}
    fnSend*: proc (chan: SigilChan[T], msg: sink Isolated[T]) {.nimcall, gcsafe.}
    fnTryRecv*: proc (chan: SigilChan[T], msg: var T): bool {.nimcall, gcsafe.}
    fnRecv*: proc (chan: SigilChan[T]): T {.nimcall, gcsafe.}

proc trySendImpl*[T](chan: SigilChan[T], msg: sink Isolated[T]): bool {.gcsafe.} =
  return chan.ch.trySend(msg)

proc sendImpl*[T](chan: SigilChan[T], msg: sink Isolated[T]) {.gcsafe.} =
  chan.ch.send(msg)

proc tryRecvImpl*[T](chan: SigilChan[T], dst: var T): bool =
  return chan.ch.tryRecv(dst)

proc recvImpl*[T](chan: SigilChan[T]): T =
  chan.ch.recv()

proc newSigilChan*[T](): SigilChan[T] =
  result.ch = newChan[T]()
  result.fnTrySend = trySendImpl[T]
  result.fnSend = sendImpl[T]
  result.fnTryRecv = tryRecvImpl[T]
  result.fnRecv = recvImpl[T]

proc trySend*[M; T: SigilChan[M]](chan: T, msg: sink Isolated[M]): bool =
  return chan.fnTrySend(chan, msg)

proc send*[M; T: SigilChan](chan: T, msg: sink Isolated[M]) =
  chan.fnSend(chan, msg)

proc tryRecv*[M; T: SigilChan](chan: T, dst: var M): bool =
  chan.fnTryRecv(chan, dst)

proc recv*[M; T: SigilChan](chan: T, tp: typedesc[M]): M =
  chan.fnRecv(chan)

