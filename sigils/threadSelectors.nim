import std/sets
import std/isolation
import std/locks
import threading/smartptrs
import threading/channels
import threading/atomics

import std/os
import std/options
import std/isolation
import std/selectors
import std/times
import std/tables

import agents
import threadBase
import threadDefault
import core

export smartptrs, isolation
export threadBase

type
  SigilSelectorThread* = object of SigilThread
    inputs*: SigilChan
    sel*: Selector[SigilTimer]
    drain*: Atomic[bool]
    isReady*: bool
    thr*: Thread[ptr SigilSelectorThread]
    timerLock*: Lock
  
  SigilSelectorThreadPtr* = ptr SigilSelectorThread

proc newSigilSelectorThread*(): ptr SigilSelectorThread =
  result = cast[ptr SigilSelectorThread](allocShared0(sizeof(SigilSelectorThread)))
  result[] = SigilSelectorThread() # important!
  result[].sel = newSelector[SigilTimer]()
  result[].agent = ThreadAgent()
  result[].signaledLock.initLock()
  result[].timerLock.initLock()
  result[].inputs = newSigilChan()
  result[].running.store(true, Relaxed)
  result[].drain.store(true, Relaxed)

method send*(
    thread: SigilSelectorThreadPtr, msg: sink ThreadSignal, blocking: BlockingKinds
) {.gcsafe.} =
  var msg = isolateRuntime(msg)
  case blocking
  of Blocking:
    thread.inputs.send(msg)
  of NonBlocking:
    let sent = thread.inputs.trySend(msg)
    if not sent:
      raise newException(MessageQueueFullError, "could not send!")

method recv*(
    thread: SigilSelectorThreadPtr, msg: var ThreadSignal, blocking: BlockingKinds
): bool {.gcsafe.} =
  case blocking
  of Blocking:
    msg = thread.inputs.recv()
    return true
  of NonBlocking:
    result = thread.inputs.tryRecv(msg)

method setTimer*(
    thread: SigilSelectorThreadPtr, timer: SigilTimer
) {.gcsafe.} =
  ## Schedule a timer on this selector-backed thread using selector timers.
  let durMs = max(timer.duration.inMilliseconds(), 1)
  withLock thread.timerLock:
    discard thread.sel.registerTimer(durMs.int, true, timer)

proc pumpTimers(thread: SigilSelectorThreadPtr, timeoutMs: int) {.gcsafe.} =
  ## Wait up to timeoutMs and deliver any due timers via selector events.
  var keys = newSeq[ReadyKey](32)
  let n = thread.sel.selectInto(timeoutMs, keys)
  for i in 0 ..< n:
    let k = keys[i]
    # Each key corresponds to a fired timer with associated 'data' = SigilTimer
    let t = getData(thread.sel, k.fd)
    if t.isNil:
      continue
    if thread.hasCancelTimer(t):
      thread.removeTimer(t)
      continue
    emit t.timeout()
    # Reschedule if needed
    if t.isRepeat():
      discard thread.sel.registerTimer(max(t.duration.inMilliseconds(), 1).int, true, t)
    else:
      if t.count > 0:
        t.count.dec()
      if t.count != 0: # schedule again while count remains
        discard thread.sel.registerTimer(max(t.duration.inMilliseconds(), 1).int, true, t)

method poll*(
    thread: SigilSelectorThreadPtr, blocking: BlockingKinds = Blocking
): bool {.gcsafe, discardable.} =
  ## Process at most one message. For Blocking, wait briefly using
  ## selectInto then try a non-blocking recv to avoid hanging when idle.
  var sig: ThreadSignal
  case blocking
  of Blocking:
    # Check timers immediately to avoid missing short intervals.
    thread.pumpTimers(0)
    thread.pumpTimers(2) # brief wait in milliseconds
    if thread.recv(sig, NonBlocking):
      thread.exec(sig)
      result = true
  of NonBlocking:
    thread.pumpTimers(0)
    if thread.recv(sig, NonBlocking):
      thread.exec(sig)
      result = true

proc runSelectorThread*(targ: SigilSelectorThreadPtr) {.thread.} =
  {.cast(gcsafe).}:
    doAssert not hasLocalSigilThread()
    setLocalSigilThread(targ)
    targ[].threadId.store(getThreadId(), Relaxed)
    emit targ[].agent.started()
    # Run until stopped; use selector timers to provide a light sleep between polls.
    while targ.isRunning():
      targ.pumpTimers(0)
      # drain any queued signals first
      while targ.poll(NonBlocking):
        discard
      # brief wait so we're not busy-spinning
      targ.pumpTimers(5)
    # final drain if requested (mirrors async variant's behavior)
    try:
      if targ.drain.load(Relaxed):
        while targ.poll(NonBlocking):
          discard
    except CatchableError:
      discard

proc start*(thread: ptr SigilSelectorThread) =
  if thread[].exceptionHandler.isNil:
    thread[].exceptionHandler = defaultExceptionHandler
  createThread(thread[].thr, runSelectorThread, thread)

proc stop*(thread: ptr SigilSelectorThread, immediate: bool = false, drain: bool = false) =
  thread[].running.store(false, Relaxed)
  thread[].drain.store(drain or immediate, Relaxed)

proc join*(thread: ptr SigilSelectorThread) =
  doAssert not thread.isNil()
  thread[].thr.joinThread()

proc peek*(thread: ptr SigilSelectorThread): int =
  result = thread[].inputs.peek()
