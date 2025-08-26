import std/locks
import std/options
import threading/smartptrs
import threading/channels
import threading/atomics

import isolateutils
import agents
import core
import threadBase

export isolateutils
export threadBase

type
  SigilThreadDefault* = object of SigilThread
    inputs*: SigilChan
    thr*: Thread[ptr SigilThreadDefault]
  
  SigilThreadDefaultPtr* = ptr SigilThreadDefault
  
method send*(
    thread: SigilThreadDefaultPtr, msg: sink ThreadSignal, blocking: BlockingKinds
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
    thread: SigilThreadDefaultPtr, msg: var ThreadSignal, blocking: BlockingKinds
): bool {.gcsafe.} =
  case blocking
  of Blocking:
    msg = thread.inputs.recv()
    return true
  of NonBlocking:
    result = thread.inputs.tryRecv(msg)

method setTimer*(
    thread: SigilThreadDefaultPtr, timer: SigilTimer
) {.gcsafe.} =
  raise newException(AssertionDefect, "not implemented for this thread type!")

proc newSigilThread*(): ptr SigilThreadDefault =
  result = cast[ptr SigilThreadDefault](allocShared0(sizeof(SigilThreadDefault)))
  result[] = SigilThreadDefault() # important!
  result[].agent = ThreadAgent()
  result[].inputs = newSigilChan()
  result[].signaledLock.initLock()
  result[].threadId.store(-1, Relaxed)
  result[].running.store(true, Relaxed)

proc startLocalThread*() =
  if not hasLocalSigilThread():
    var st = newSigilThread()
    st[].threadId.store(getThreadId(), Relaxed)
    setLocalSigilThread(st)

if getStartSigilThreadProc().isNil:
  setStartSigilThreadProc(startLocalThread)

method poll*(
    thread: SigilThreadDefaultPtr, blocking: BlockingKinds = Blocking
) {.gcsafe.} =
  var sig: ThreadSignal
  case blocking
  of Blocking:
    discard thread.recv(sig, Blocking)
    thread.exec(sig)
  of NonBlocking:
    if thread.recv(sig, NonBlocking):
      thread.exec(sig)

proc runForever*(thread: SigilThreadDefaultPtr) =
  emit thread.agent.started()
  while isRunning(thread):
    try:
      thread.poll()
    except CatchableError as e:
      if thread.exceptionHandler.isNil:
        raise e
      else:
        thread.exceptionHandler(e)
    except Defect as e:
      if thread.exceptionHandler.isNil:
        raise e
      else:
        thread.exceptionHandler(e)
    except Exception as e:
      if thread.exceptionHandler.isNil:
        raise e
      else:
        thread.exceptionHandler(e)

proc runThread*(thread: SigilThreadDefaultPtr) {.thread.} =
  {.cast(gcsafe).}:
    pcnt.inc
    pidx = pcnt
    doAssert not hasLocalSigilThread()
    setLocalSigilThread(thread)
    thread[].threadId.store(getThreadId(), Relaxed)
    debugPrint "Sigil worker thread waiting!"
    thread.runForever()

proc start*(thread: SigilThreadDefaultPtr) =
  if thread[].exceptionHandler.isNil:
    thread[].exceptionHandler = defaultExceptionHandler
  createThread(thread[].thr, runThread, thread)

proc join*(thread: SigilThreadDefaultPtr) =
  doAssert not thread.isNil()
  thread[].thr.joinThread()

proc peek*(thread: SigilThreadDefaultPtr): int =
  result = thread[].inputs.peek()
