import std/sets
import std/isolation
import std/locks
import threading/smartptrs
import threading/channels
import threading/atomics

import std/os
import std/monotimes
import std/options
import std/isolation
import std/uri
import std/asyncdispatch

import agents
import threadBase
import core

export smartptrs, isolation
export threadBase

type
  AsyncSigilThread* = object of SigilThread
    inputs*: SigilChan
    event*: AsyncEvent
    drain*: Atomic[bool]
    thr*: Thread[ptr AsyncSigilThread]
  
  AsyncSigilThreadPtr* = ptr AsyncSigilThread

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
    thread: AsyncSigilThreadPtr, msg: sink ThreadSignal, blocking: BlockingKinds
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
    thread: AsyncSigilThreadPtr, msg: var ThreadSignal, blocking: BlockingKinds
): bool {.gcsafe.} =
  debugPrint "threadRecv: ", thread.id
  case blocking
  of Blocking:
    msg = thread.inputs.recv()
    return true
  of NonBlocking:
    result = thread.inputs.tryRecv(msg)
  thread.event.trigger()

method setTimer*(
    thread: AsyncSigilThreadPtr, timer: SigilTimer
) {.gcsafe.} =
  if timer.repeat == -1:
    proc cb(fd: AsyncFD): bool {.closure, gcsafe.} =
      if thread.hasCancelTimer(timer):
        return true # stop timer
      else:
        emit timer.timeout()
        return false
    asyncdispatch.addTimer(timer.duration.inMilliseconds(), oneshot=false, cb)
  else:
    proc cb(fd: AsyncFD): bool {.closure, gcsafe.} =
      if timer.repeat > 0 and thread.hasCancelTimer(timer):
        return true # stop timer
      else:
        emit timer.timeout()
        asyncdispatch.addTimer(timer.duration.inMilliseconds(), oneshot=true, cb)
        return false
    asyncdispatch.addTimer(timer.duration.inMilliseconds(), oneshot=true, cb)

proc runAsyncThread*(targ: ptr AsyncSigilThread) {.thread.} =
  var
    thread = targ
    sthr = thread.toSigilThread()
  echo "async sigil thread waiting!", " (th: ", getThreadId(), ")"

  let cb = proc(fd: AsyncFD): bool {.closure, gcsafe.} =
      # echo "async thread running "
      var sig: ThreadSignal
      while isRunning(thread) and thread.recv(sig, NonBlocking):
        try:
          sthr.exec(sig)
        except CatchableError as e:
          if sthr[].exceptionHandler.isNil:
            raise e
          else:
            sthr[].exceptionHandler(e)
        except Exception as e:
          if sthr[].exceptionHandler.isNil:
            raise e
          else:
            sthr[].exceptionHandler(e)
        except Defect as e:
          if sthr[].exceptionHandler.isNil:
            raise e
          else:
            sthr[].exceptionHandler(e)

  thread[].event.addEvent(cb)
  while thread.drain.load(Relaxed):
    poll()

  try:
    if thread.drain.load(Relaxed):
      asyncdispatch.drain()
  except ValueError:
    discard

proc startLocalThreadDispatch*() =
  if not hasLocalSigilThread():
    var st = newSigilAsyncThread()
    st[].threadId.store(getThreadId(), Relaxed)
    setLocalSigilThread(st)

proc start*(thread: ptr AsyncSigilThread) =
  if thread[].exceptionHandler.isNil:
    thread[].exceptionHandler = defaultExceptionHandler
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
