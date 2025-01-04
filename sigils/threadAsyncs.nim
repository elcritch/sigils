import std/sets
import std/isolation
import threading/smartptrs
import threading/channels

import agents
import threads
import core

export smartptrs, isolation
export threads

import std/os
import std/monotimes
import std/options
import std/isolation
import std/uri
import std/asyncdispatch

type

  AsyncSigilThreadObj* = ref object of SigilThreadBase
    thr*: Thread[SharedPtr[AsyncSigilThreadObj]]
    event*: AsyncEvent

  SharedPtr[AsyncSigilThread]* = SharedPtr[AsyncSigilThreadObj]

proc newSigilAsyncThread*(): SharedPtr[AsyncSigilThread] =
  result = newSharedPtr(isolate AsyncSigilThreadObj())
  result[].event = newAsyncEvent()
  result[].inputs = newSigilChan()
  echo "newSigilAsyncThread: ", result[].event.repr

proc runAsyncThread*(thread: SharedPtr[AsyncSigilThread]) {.thread.} =
  var
    event: AsyncEvent = thread[].event
  echo "async sigil thread waiting!", " (th: ", getThreadId(), ")"

  let cb = proc(fd: AsyncFD): bool {.closure, gcsafe.} =
    {.cast(gcsafe).}:
      var sig: ThreadSignal
      echo "async thread running "
      while thread.inputs.tryRecv(sig):
        echo "async thread got msg: "
        thread[].poll(sig)

  event.addEvent(cb)
  runForever()

proc start*(thread: SharedPtr[AsyncSigilThread]) =
  createThread(thread[].thr, runAsyncThread, thread)
