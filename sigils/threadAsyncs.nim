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

  AsyncSigilChan* = ref object of SigilChan
    event*: AsyncEvent

method trySend*[T](chan: AsyncSigilChan, msg: sink Isolated[T]): bool {.gcsafe.} =
  result = chan.ch.trySend(msg)
  echo "TRIGGER send try: ", result
  if result:
    chan.event.trigger()

method send*[T](chan: AsyncSigilChan, msg: sink Isolated[T]) {.gcsafe.} =
  chan.ch.send(msg)
  echo "TRIGGER send: ", chan.event.repr
  chan.event.trigger()

proc newAsyncSigilChan*[T](event: AsyncEvent): AsyncSigilChan =
  result.new()
  result.ch = newChan[ThreadSignal]()
  result.event = event

proc newSigilAsyncThread*(): AsyncSigilThread =
  result = newSharedPtr(AsyncSigilThreadObj())
  let
    event = newAsyncEvent()
    inputs = newAsyncSigilChan[ThreadSignal](event)
  result[].event = event
  result[].inputs = inputs
  echo "newSigilAsyncThread: ", result[].event.repr
  echo "newSigilAsyncThread: ", result[].inputs.repr

proc runAsyncThread*(thread: AsyncSigilThread) {.thread.} =
  var
    event: AsyncEvent = thread[].event
    # event: AsyncEvent = thread[].event
    inputs = thread[].inputs
  echo "async sigil thread waiting!", " evt: ", event.repr, " (", getThreadId(), ")"

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
