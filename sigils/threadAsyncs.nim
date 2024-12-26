import std/sets
import std/isolation
import threading/smartptrs
import threading/channels

import agents
import threads
import chans
import core

export chans, smartptrs, threads, isolation

import std/os
import std/monotimes
import std/options
import std/isolation
import std/uri
import std/asyncdispatch

type

  AsyncSigilThreadObj* = object of SigilThreadBase
    thr*: Thread[SharedPtr[AsyncSigilThreadObj]]
    event*: AsyncEvent

  AsyncSigilThread* = SharedPtr[AsyncSigilThreadObj]

  AsyncSigilChan*[T] = object of SigilChan[T]
    event*: AsyncEvent

proc trySendImplAsync*[T](chan: AsyncSigilChan[T], msg: sink Isolated[T]): bool {.gcsafe.} =
  return chan.ch.trySend(msg)

proc sendImplAsync*[T](chan: AsyncSigilChan[T], msg: sink Isolated[T]) {.gcsafe.} =
  chan.ch.send(msg)

proc tryRecvImplAsync*[T](chan: AsyncSigilChan[T], dst: var T): bool =
  return chan.ch.tryRecv(dst)

proc recvImplAsync*[T](chan: AsyncSigilChan[T]): T =
  chan.ch.recv()

proc newAsyncSigilChan*[T](event: AsyncEvent): AsyncSigilChan[T] =
  result.ch = newChan[T]()
  result.fnTrySend = trySendImplAsync[T]
  result.fnSend = sendImplAsync[T]
  result.fnTryRecv = tryRecvImplAsync[T]
  result.fnRecv = recvImplAsync[T]
  result.event = event

proc newSigilAsyncThread*(): AsyncSigilThread =
  result = newSharedPtr(AsyncSigilThreadObj())
  result[].event = newAsyncEvent()
  result[].inputs = newAsyncSigilChan[ThreadSignal](result[].event)

proc runAsyncThread*(thread: AsyncSigilThread) {.thread.} =
  var
    event: AsyncEvent = thread[].event
    # event: AsyncEvent = thread[].event
    inputs = thread[].inputs
  echo "sigil thread waiting!", " (", getThreadId(), ")"

  let cb = proc(fd: AsyncFD): bool {.closure, gcsafe.} =
    {.cast(gcsafe).}:
      var sig: ThreadSignal
      if inputs.tryRecv(sig):
        echo "async thread run: "
        discard sig.tgt[].callMethod(sig.req, sig.slot)

  event.addEvent(cb)
  runForever()

proc start*(thread: AsyncSigilThread) =
  createThread(thread[].thr, runAsyncThread, thread)
