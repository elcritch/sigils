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

method trySend*(chan: AsyncSigilChan, msg: sink Isolated[ThreadSignal]): bool {.gcsafe.} =
  echo "TRIGGER send try: "
  result = chan.ch.trySend(msg)
  if result:
    chan.event.trigger()

method send*(chan: AsyncSigilChan, msg: sink Isolated[ThreadSignal]) {.gcsafe.} =
  echo "TRIGGER send: ", chan.event.repr
  chan.ch.send(msg)
  chan.event.trigger()

method tryRecv*(chan: AsyncSigilChan, dst: var ThreadSignal): bool {.gcsafe.} =
  echo "TRIGGER recv try: ", " (th: ", getThreadId(), ")"
  result = chan.ch.tryRecv(dst)

method recv*(chan: AsyncSigilChan): ThreadSignal {.gcsafe.} =
  echo "TRIGGER recv: ", " (th: ", getThreadId(), ")"
  chan.ch.recv()

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
  echo "newSigilAsyncThread: ", result[].inputs.AsyncSigilChan.repr

proc runAsyncThread*(thread: AsyncSigilThread) {.thread.} =
  var
    event: AsyncEvent = thread[].event
    inputs = thread[].inputs.AsyncSigilChan
  echo "async sigil thread waiting!", " evt: ", inputs.repr, " (th: ", getThreadId(), ")"

  let cb = proc(fd: AsyncFD): bool {.closure, gcsafe.} =
    {.cast(gcsafe).}:
      var sig: ThreadSignal
      if inputs.tryRecv(sig):
        echo "async thread run: "
        thread[].poll(sig)

  event.addEvent(cb)
  runForever()

proc start*(thread: AsyncSigilThread) =
  createThread(thread[].thr, runAsyncThread, thread)
