import std/sets
import std/isolation
import threading/smartptrs
import threading/channels

import agents
import threads
import core

export channels, smartptrs, threads, isolation

import std/os
import std/monotimes
import std/options
import std/isolation
import std/uri
import std/asyncdispatch

type
  AsyncAgentProxy*[T] = ref object of AgentProxy[T]
    event*: AsyncEvent

  AsyncSigilThreadObj* = object of SigilThreadBase
    thr*: Thread[SharedPtr[AsyncSigilThreadObj]]
    event*: AsyncEvent

  AsyncSigilThread* = SharedPtr[AsyncSigilThreadObj]

proc newSigilAsyncThread*(): AsyncSigilThread =
  result = newSharedPtr(AsyncSigilThreadObj())
  result[].inputs = newChan[ThreadSignal]()
  result[].event = newAsyncEvent()

proc runAsyncThread*(thread: AsyncSigilThread) {.thread.} =
  var
    event: AsyncEvent = thread[].event
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
  let args = (thread[].event, thread[].inputs)
  createThread(thread[].thr, runAsyncThread, thread)
