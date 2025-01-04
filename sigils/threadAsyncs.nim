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

  AsyncSigilThreadObj* = object of SigilThreadBase
    thr*: Thread[SharedPtr[AsyncSigilThreadObj]]
    event*: AsyncEvent

  AsyncSigilThread* = SharedPtr[AsyncSigilThreadObj]

proc newSigilAsyncThread*(): AsyncSigilThread =
  result = newSharedPtr(AsyncSigilThreadObj())
  result[].event = newAsyncEvent()
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
