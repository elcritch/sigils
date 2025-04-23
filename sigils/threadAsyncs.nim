import std/sets
import std/isolation
import std/locks
import threading/smartptrs
import threading/channels
import threading/atomics

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

type AsyncSigilThread* = object of SigilThread
  inputs*: SigilChan
  event*: AsyncEvent
  drain*: Atomic[bool]
  thr*: Thread[ptr AsyncSigilThread]

proc newSigilAsyncThread*(): ptr AsyncSigilThread =
  result = cast[ptr AsyncSigilThread](allocShared0(sizeof(AsyncSigilThread)))
  result[] = AsyncSigilThread() # important!
  result[].event = newAsyncEvent()
  result[].signaledLock.initLock()
  result[].inputs = newSigilChan()
  result[].running.store(true, Relaxed)
  result[].drain.store(true, Relaxed)
  echo "newSigilAsyncThread: ", result[].event.repr

method send*(
    thread: AsyncSigilThread, msg: sink ThreadSignal, blocking: BlockingKinds
) {.gcsafe.} =
  debugPrint "threadSend: ", thread.id
  var msg = isolateRuntime(msg)
  case blocking
  of Blocking:
    thread.inputs.send(msg)
  of NonBlocking:
    let sent = thread.inputs.trySend(msg)
    if not sent:
      raise newException(MessageQueueFullError, "could not send!")
  thread.event.trigger()

method recv*(
    thread: AsyncSigilThread, msg: var ThreadSignal, blocking: BlockingKinds
): bool {.gcsafe.} =
  debugPrint "threadRecv: ", thread.id
  case blocking
  of Blocking:
    msg = thread.inputs.recv()
    return true
  of NonBlocking:
    result = thread.inputs.tryRecv(msg)
  thread.event.trigger()

proc runAsyncThread*(targ: ptr AsyncSigilThread) {.thread.} =
  var
    thread = targ
    sthr = thread.toSigilThread()
  echo "async sigil thread waiting!", " (th: ", getThreadId(), ")"

  let cb = proc(fd: AsyncFD): bool {.closure, gcsafe.} =
    {.cast(gcsafe).}:
      # echo "async thread running "
      var sig: ThreadSignal
      while isRunning(thread[]) and thread[].recv(sig, NonBlocking):
        sthr[].exec(sig)


  thread[].event.addEvent(cb)
  while thread.drain.load(Relaxed):
    poll()

  try:
    if thread.drain.load(Relaxed):
      asyncdispatch.drain()
  except ValueError:
    discard

proc start*(thread: ptr AsyncSigilThread) =
  createThread(thread[].thr, runAsyncThread, thread)

proc stop*(thread: ptr AsyncSigilThread, immediate: bool = false, drain: bool = false) =
  thread[].running.store(false, Relaxed)
  thread[].drain.store(drain, Relaxed)
  if immediate:
    thread[].drain.store(true, Relaxed)
  else:
    thread[].event.trigger()

proc join*(thread: ptr AsyncSigilThread) =
  thread[].thr.joinThread()

proc peek*(thread: ptr AsyncSigilThread): int =
  result = thread[].inputs.peek()
