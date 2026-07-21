## Chronos-backed Sigils thread dispatch.
##
## Unlike the stdlib async dispatcher implementation, this thread sleeps in
## Chronos' OS event loop while idle. A cross-thread ``ThreadSignal`` wakes the
## dispatcher after a message or timer request is queued.

import std/[isolation, locks]
from std/times import inMilliseconds

import threading/[atomics, channels, smartptrs]
import chronos
import chronos/threadsync as chronosThreadSync except ThreadSignal

import core
import threadBase

export isolation, smartptrs
export threadBase

type
  SigilChronosThread* = object of SigilThread
    inputs: SigilChan
    wake: chronosThreadSync.ThreadSignalPtr
    drain: Atomic[bool]
    wakeClosed: Atomic[bool]
    thr: Thread[ptr SigilChronosThread]
    timerLock: Lock
    pendingTimers: seq[SigilTimer]
    timerTasks: seq[Future[void]]

  SigilChronosThreadPtr* = ptr SigilChronosThread

proc wakeDispatcher(thread: SigilChronosThreadPtr) {.gcsafe.} =
  if thread.wakeClosed.load(Relaxed):
    raise newException(IOError, "Chronos thread wake signal is closed")

  let wakeResult = chronosThreadSync.fireSync(thread.wake)
  if wakeResult.isErr():
    raise newException(IOError, wakeResult.error())
  if not wakeResult.get():
    raise newException(IOError, "timed out waking Chronos thread")

proc newSigilChronosThread*(): SigilChronosThreadPtr =
  let wakeResult = chronosThreadSync.ThreadSignalPtr.new()
  if wakeResult.isErr():
    raise newException(IOError, wakeResult.error())

  result = cast[SigilChronosThreadPtr](allocShared0(sizeof(SigilChronosThread)))
  result[] = SigilChronosThread()
  result.agent = SigilThreadAgent()
  result.inputs = newSigilChan()
  result.wake = wakeResult.get()
  result.signaledLock.initLock()
  result.timerLock.initLock()
  result.threadId.store(-1, Relaxed)
  result.running.store(true, Relaxed)
  result.drain.store(false, Relaxed)
  result.wakeClosed.store(false, Relaxed)

method send*(
    thread: SigilChronosThreadPtr,
    msg: sink ThreadSignal,
    blocking: BlockingKinds,
) {.gcsafe.} =
  var isolatedMsg = isolateRuntime(msg)
  case blocking
  of Blocking:
    thread.inputs.send(isolatedMsg)
  of NonBlocking:
    if not thread.inputs.trySend(isolatedMsg):
      raise newException(MessageQueueFullError, "could not send")

  debugQueuePrint "queue:Chronos thread inputs size: ",
    $thread.inputs.peek(), " thread: ", $getThreadId(thread.toSigilThread()[])
  thread.wakeDispatcher()

method recv*(
    thread: SigilChronosThreadPtr,
    msg: var ThreadSignal,
    blocking: BlockingKinds,
): bool {.gcsafe.} =
  case blocking
  of Blocking:
    msg = thread.inputs.recv()
    result = true
  of NonBlocking:
    result = thread.inputs.tryRecv(msg)

proc handleThreadException(
    thread: SigilChronosThreadPtr,
    error: ref Exception,
) {.gcsafe, raises: [].} =
  if thread.exceptionHandler.isNil:
    defaultExceptionHandler(error)
  else:
    {.cast(raises: []).}:
      thread.exceptionHandler(error)

proc execOne(thread: SigilChronosThreadPtr): bool {.gcsafe, raises: [].} =
  var sig: ThreadSignal
  try:
    if thread.recv(sig, NonBlocking):
      result = true
      thread.exec(sig)
  except CatchableError as error:
    thread.handleThreadException(error)
  except Defect as error:
    thread.handleThreadException(error)
  except Exception as error:
    thread.handleThreadException(error)

proc runTimer(
    thread: SigilChronosThreadPtr,
    timer: SigilTimer,
): Future[void] {.async.} =
  try:
    let delay = max(timer.duration.inMilliseconds(), 1).milliseconds
    while timer.isRepeat() or timer.count > 0:
      await sleepAsync(delay)
      if thread.hasCancelTimer(timer):
        thread.removeTimer(timer)
        break

      emit timer.timeout()
      if not timer.isRepeat():
        timer.count.dec()
      thread.wakeDispatcher()
  except CancelledError:
    discard
  except CatchableError as error:
    thread.handleThreadException(error)
  except Defect as error:
    thread.handleThreadException(error)
  except Exception as error:
    thread.handleThreadException(error)

proc startPendingTimers(thread: SigilChronosThreadPtr) {.gcsafe.} =
  var pending: seq[SigilTimer]
  withLock thread.timerLock:
    pending = move thread.pendingTimers

  for timer in pending:
    thread.timerTasks.add(thread.runTimer(timer))

proc collectFinishedTimers(thread: SigilChronosThreadPtr) {.gcsafe.} =
  var index = thread.timerTasks.high
  while index >= 0:
    if thread.timerTasks[index].finished():
      thread.timerTasks.delete(index)
    index.dec()

proc cancelTimerTasks(thread: SigilChronosThreadPtr): Future[void] {.async.} =
  for task in thread.timerTasks:
    await task.cancelAndWait()
  thread.timerTasks.setLen(0)

method setTimer*(
    thread: SigilChronosThreadPtr,
    timer: SigilTimer,
) {.gcsafe.} =
  withLock thread.timerLock:
    thread.pendingTimers.add(timer)
  thread.wakeDispatcher()

proc consumeWake(thread: SigilChronosThreadPtr) {.gcsafe.} =
  let waitResult = chronosThreadSync.waitSync(thread.wake, ZeroDuration)
  if waitResult.isErr():
    raise newException(IOError, waitResult.error())

method poll*(
    thread: SigilChronosThreadPtr,
    blocking: BlockingKinds = Blocking,
): bool {.gcsafe, discardable.} =
  thread.startPendingTimers()
  thread.collectFinishedTimers()

  case blocking
  of Blocking:
    thread.consumeWake()
    if thread.execOne():
      return true
    waitFor chronosThreadSync.wait(thread.wake)
    thread.startPendingTimers()
    thread.collectFinishedTimers()
    result = thread.execOne() or thread.isRunning()
  of NonBlocking:
    thread.consumeWake()
    waitFor sleepAsync(ZeroDuration)
    thread.startPendingTimers()
    thread.collectFinishedTimers()
    result = thread.execOne()

proc runChronosLoop(thread: SigilChronosThreadPtr): Future[void] {.async.} =
  try:
    emit thread.agent.started()
  except CatchableError as error:
    thread.handleThreadException(error)
  except Defect as error:
    thread.handleThreadException(error)
  except Exception as error:
    thread.handleThreadException(error)

  while thread.isRunning():
    thread.startPendingTimers()
    thread.collectFinishedTimers()
    while thread.isRunning() and thread.execOne():
      discard
    if thread.isRunning():
      await chronosThreadSync.wait(thread.wake)

  if thread.drain.load(Relaxed):
    while thread.execOne():
      discard
  await thread.cancelTimerTasks()

proc runChronosThread*(thread: SigilChronosThreadPtr) {.thread.} =
  {.cast(gcsafe).}:
    doAssert not hasLocalSigilThread()
    setThreadDispatcher(newDispatcher())
    setLocalSigilThread(thread)
    thread.threadId.store(getThreadId(), Relaxed)
    try:
      waitFor thread.runChronosLoop()
    except CatchableError as error:
      thread.handleThreadException(error)
    except Defect as error:
      thread.handleThreadException(error)
    except Exception as error:
      thread.handleThreadException(error)

proc startLocalThreadChronos*() =
  if not hasLocalSigilThread():
    let thread = newSigilChronosThread()
    thread.threadId.store(getThreadId(), Relaxed)
    setLocalSigilThread(thread)

proc start*(thread: SigilChronosThreadPtr) =
  if thread.exceptionHandler.isNil:
    thread.exceptionHandler = defaultExceptionHandler
  createThread(thread.thr, runChronosThread, thread)

proc stop*(
    thread: SigilChronosThreadPtr,
    immediate = false,
    drain = false,
) =
  thread.drain.store(drain and not immediate, Relaxed)
  thread.running.store(false, Relaxed)
  thread.wakeDispatcher()

proc close*(thread: SigilChronosThreadPtr) =
  if thread.wakeClosed.exchange(true, AcqRel):
    return

  if thread.timerTasks.len > 0:
    waitFor thread.cancelTimerTasks()
  withLock thread.timerLock:
    thread.pendingTimers.setLen(0)

  let closeResult = chronosThreadSync.close(thread.wake)
  if closeResult.isErr():
    raise newException(IOError, closeResult.error())

proc join*(thread: SigilChronosThreadPtr) =
  doAssert not thread.isNil()
  thread.thr.joinThread()
  thread.close()

proc peek*(thread: SigilChronosThreadPtr): int =
  thread.inputs.peek()
