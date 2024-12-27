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

  AsyncSigilChan* = ref object of SigilChanRef
    event*: AsyncEvent

method trySend*(chan: AsyncSigilChan, msg: sink Isolated[ThreadSignal]): bool {.gcsafe.} =
  echo "TRIGGER send try: ", " msg: ", $msg, " (th: ", getThreadId(), ")"
  result = chan.ch.trySend(msg)
  echo "TRIGGER send try: ", result, " (th: ", getThreadId(), ")"
  if result:
    chan.event.trigger()

method send*(chan: AsyncSigilChan, msg: sink Isolated[ThreadSignal]) {.gcsafe.} =
  echo "TRIGGER send: ", $msg, " evt: ", chan.event.repr, " (th: ", getThreadId(), ")"
  chan.ch.send(msg)
  chan.event.trigger()

method tryRecv*(chan: AsyncSigilChan, dst: var ThreadSignal): bool {.gcsafe.} =
  result = chan.ch.tryRecv(dst)
  echo "TRIGGER recv try: ", result, " (th: ", getThreadId(), ")"

method recv*(chan: AsyncSigilChan): ThreadSignal {.gcsafe.} =
  echo "TRIGGER recv: ", " (th: ", getThreadId(), ")"
  chan.ch.recv()

proc newAsyncSigilChan*[T](event: AsyncEvent): SigilChan =
  var sch = AsyncSigilChan.new()
  sch.ch = newChan[ThreadSignal]()
  sch.event = event
  result = newSharedPtr(isolateRuntime sch.SigilChanRef)

proc newSigilAsyncThread*(): AsyncSigilThread =
  result = newSharedPtr(AsyncSigilThreadObj())
  let
    event = newAsyncEvent()
    inputs = newAsyncSigilChan[ThreadSignal](event)
  result[].event = event
  result[].inputs = inputs
  echo "newSigilAsyncThread: ", result[].event.repr
  echo "newSigilAsyncThread: ", result[].inputs[].AsyncSigilChan.repr

proc runAsyncThread*(thread: AsyncSigilThread) {.thread.} =
  var
    event: AsyncEvent = thread[].event
    inputs = thread[].inputs[].AsyncSigilChan
  echo "async sigil thread waiting!", " evt: ", inputs.repr, " (th: ", getThreadId(), ")"

  let cb = proc(fd: AsyncFD): bool {.closure, gcsafe.} =
    {.cast(gcsafe).}:
      var sig: ThreadSignal
      echo "async thread running "
      while inputs.tryRecv(sig):
        echo "async thread got msg: "
        thread[].poll(sig)

  event.addEvent(cb)
  runForever()

proc start*(thread: AsyncSigilThread) =
  createThread(thread[].thr, runAsyncThread, thread)
