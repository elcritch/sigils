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

import agents
import threadBase
import threadDefault
import core

export smartptrs, isolation
export threadBase

type
  SigilSelectorThread* = object of SigilThread
    inputs*: SigilChan
    sel*: Selector[int]
    drain*: Atomic[bool]
    isReady*: bool
    thr*: Thread[ptr SigilSelectorThread]
  
  SigilSelectorThreadPtr* = ptr SigilSelectorThread

proc newSigilSelectorThread*(): ptr SigilSelectorThread =
  result = cast[ptr SigilSelectorThread](allocShared0(sizeof(SigilSelectorThread)))
  result[] = SigilSelectorThread() # important!
  result[].sel = newSelector[int]()
  result[].agent = ThreadAgent()
  result[].signaledLock.initLock()
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
  ## For the selector-based thread variant, timers are not yet implemented.
  ## This mirrors threadDefault's behavior and keeps the implementation
  ## focused on selector-driven message processing.
  raise newException(AssertionDefect, "not implemented for this thread type!")

method poll*(
    thread: SigilSelectorThreadPtr, blocking: BlockingKinds = Blocking
): bool {.gcsafe, discardable.} =
  ## Process at most one message. For Blocking, wait briefly using
  ## selectInto then try a non-blocking recv to avoid hanging when idle.
  var sig: ThreadSignal
  case blocking
  of Blocking:
    var events: seq[ReadyKey] = @[]
    discard thread.sel.selectInto(2, events) # brief wait in milliseconds
    if thread.recv(sig, NonBlocking):
      thread.exec(sig)
      result = true
  of NonBlocking:
    if thread.recv(sig, NonBlocking):
      thread.exec(sig)
      result = true

proc runSelectorThread*(targ: SigilSelectorThreadPtr) {.thread.} =
  {.cast(gcsafe).}:
    doAssert not hasLocalSigilThread()
    setLocalSigilThread(targ)
    targ[].threadId.store(getThreadId(), Relaxed)
    emit targ[].agent.started()
    # Run until stopped; use selectInto to provide a light sleep between polls.
    var events: seq[ReadyKey] = @[]
    while targ.isRunning():
      # drain any queued signals first
      while targ.poll(NonBlocking):
        discard
      # brief wait so we're not busy-spinning
      discard targ[].sel.selectInto(5, events)
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
