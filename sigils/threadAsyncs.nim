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

  AsyncSigilThread* = ref object of SigilThread
    inputs*: SigilChan
    event*: AsyncEvent

proc newSigilAsyncThread*(): SharedPtr[AsyncSigilThread] =
  result = newSharedPtr(isolate AsyncSigilThread())
  result[].event = newAsyncEvent()
  result[].inputs = newSigilChan()
  echo "newSigilAsyncThread: ", result[].event.repr

proc runAsyncThread*(targ: SharedPtr[SigilThread]) {.thread.} =
  var
    thread = targ
  echo "async sigil thread waiting!", " (th: ", getThreadId(), ")"

  let cb = proc(fd: AsyncFD): bool {.closure, gcsafe.} =
    {.cast(gcsafe).}:
      echo "async thread running "
      var sig: ThreadSignal
      while thread[].recv(sig, NonBlocking):
        echo "async thread got msg: "
        thread[].exec(sig)

  thread[].event.addEvent(cb)
  runForever()

proc start*(thread: SharedPtr[AsyncSigilThread]) =
  createThread(thread[].thr, runAsyncThread, thread)
