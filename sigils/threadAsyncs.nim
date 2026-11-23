import std/sets
import std/isolation
import std/locks
import threading/smartptrs
import threading/channels
import std/atomics

import std/os
import std/monotimes
import std/options
import std/isolation
import std/uri
import std/asyncdispatch
from std/times import initDuration, inMilliseconds

import agents
import threadBase
import threadDefault
import core

export smartptrs, isolation
export threadBase

const DrainTimeoutMs = 500

type
  AsyncSigilThread* = object of SigilThread
    inputs*: SigilChan
    event*: AsyncEvent
    drain*: Atomic[bool]
    isReady*: bool
    thr*: Thread[ptr AsyncSigilThread]

  AsyncSigilThreadPtr* = ptr AsyncSigilThread

proc newSigilAsyncThread*(): ptr AsyncSigilThread =
  result = cast[ptr AsyncSigilThread](allocShared0(sizeof(AsyncSigilThread)))
  result[] = AsyncSigilThread() # important!
  result[].event = newAsyncEvent()
  result[].agent = SigilThreadAgent()
  result[].signaledLock.initLock()
  result[].inputs = newSigilChan()
  result[].running.store(true, moRelaxed)
  result[].drain.store(true, moRelaxed)

method send*(
    thread: AsyncSigilThreadPtr, msg: sink ThreadSignal, blocking: BlockingKinds
) {.gcsafe.} =
  debugPrint "threadSend: ", thread.toSigilThread()[].getThreadId()
  var prepared = ensureMove(msg)
  prepared.prepareDelivery()
  var msg = isolateRuntime(move(prepared))
  case blocking
  of Blocking:
    thread.inputs.send(msg)
  of NonBlocking:
    let sent = thread.inputs.trySend(msg)
    if not sent:
      raise newException(MessageQueueFullError, "could not send!")
  debugQueuePrint "queue:thread inputs size: ", $thread.inputs.peek(),
    " thread: ", $getThreadId(thread.toSigilThread()[])
  thread.toSigilThread().notifyMessageEnqueued()
  thread.event.trigger()

method recv*(
    thread: AsyncSigilThreadPtr, msg: var ThreadSignal, blocking: BlockingKinds
): bool {.gcsafe.} =
  debugPrint "threadRecv: ", thread.toSigilThread()[].getThreadId(),
      " blocking: ", blocking
  case blocking
  of Blocking:
    msg = thread.inputs.recv()
    return true
  of NonBlocking:
    result = thread.inputs.tryRecv(msg)

method setTimer*(
    thread: AsyncSigilThreadPtr, timer: SigilTimer
) {.gcsafe.} =
  if timer.isRepeat():
    proc cb(fd: AsyncFD): bool {.closure, gcsafe.} =
      if thread.hasCancelTimer(timer):
        thread.removeTimer(timer)
        return true # stop timer
      else:
        emit timer.timeout()
        return false
    asyncdispatch.addTimer(timer.timerMilliseconds(), oneshot = false, cb)
  else:
    proc cb(fd: AsyncFD): bool {.closure, gcsafe.} =
      if timer.count == 0 or thread.hasCancelTimer(timer):
        thread.removeTimer(timer)
        return true # stop timer
      emit timer.timeout()
      timer.count.dec()
      if timer.count == 0 or thread.hasCancelTimer(timer):
        thread.removeTimer(timer)
      else:
        asyncdispatch.addTimer(timer.timerMilliseconds(), oneshot = true, cb)
      return true # release this one-shot registration
    asyncdispatch.addTimer(timer.timerMilliseconds(), oneshot = true, cb)

proc execOne(thread: AsyncSigilThreadPtr): bool {.gcsafe.} =
  var sig: ThreadSignal
  if not thread.recv(sig, NonBlocking):
    return false

  try:
    thread.exec(sig)
  except Exception as error:
    if thread[].exceptionHandler.isNil:
      raise
    thread[].exceptionHandler(error)
  return true

proc setupThread*(thread: ptr AsyncSigilThread) =
  if thread[].isReady:
    return
  thread[].isReady = true

  let cb = proc(fd: AsyncFD): bool {.closure, gcsafe.} =
    while thread.isRunning() and thread.execOne():
      discard
  thread[].event.addEvent(cb)

method poll*(thread: AsyncSigilThreadPtr,
    blocking: BlockingKinds = Blocking): bool {.gcsafe, discardable.} =
  if not thread[].isReady:
    thread.setupThread()

  case blocking
  of Blocking:
    asyncdispatch.poll()
    result = true
  of NonBlocking:
    asyncdispatch.poll(1)
    result = false

proc runAsyncThread*(targ: AsyncSigilThreadPtr) {.thread.} =
  var
    thread = targ

  doAssert not hasLocalSigilThread()
  setGlobalDispatcher(newDispatcher())
  setLocalSigilThread(thread)

  thread.setupThread()
  while thread[].running.load(moAcquire):
    # A finite wait lets asyncdispatch wake for sleepAsync timers.
    asyncdispatch.poll()

  if thread.drain.load(moRelaxed):
    let deadline = getMonoTime() + initDuration(milliseconds = DrainTimeoutMs)
    while true:
      while thread.execOne():
        discard
      let remainingMs = inMilliseconds(deadline - getMonoTime()).int
      if remainingMs <= 0:
        break
      try:
        asyncdispatch.poll(remainingMs)
      except ValueError:
        break

proc startLocalThreadDispatch*() =
  if not hasLocalSigilThread():
    var st = newSigilAsyncThread()
    st[].threadId.store(getThreadId(), moRelaxed)
    setLocalSigilThread(st)

proc start*(thread: ptr AsyncSigilThread) =
  if thread[].exceptionHandler.isNil:
    thread[].exceptionHandler = defaultExceptionHandler
  createThread(thread[].thr, runAsyncThread, thread)

proc stop*(thread: ptr AsyncSigilThread, immediate: bool = false,
    drain: bool = false) =
  ## Wake the worker. Draining processes queued signals and polls the async
  ## dispatcher for up to 500 ms. Immediate shutdown skips draining.
  thread[].drain.store(drain and not immediate, moRelaxed)
  thread[].running.store(false, moRelease)
  thread[].event.trigger()

proc join*(thread: ptr AsyncSigilThread) =
  thread[].thr.joinThread()

proc peek*(thread: ptr AsyncSigilThread): int =
  result = thread[].inputs.peek()
