import std/sets
import std/isolation
import std/options
import std/locks
import threading/smartptrs
import threading/channels
import threading/atomics

import isolateutils
import agents
import core

from system/ansi_c import c_raise

export smartptrs, isolation, channels
export isolateutils

type
  SigilTimer* = ref object of Agent
    duration*: Duration
    repeat*: int = -1 # -1 for repeat forever, N > 0 for N times

  MessageQueueFullError* = object of CatchableError

  BlockingKinds* {.pure.} = enum
    Blocking
    NonBlocking

  ThreadSignalKind* {.pure.} = enum
    Call
    Move
    Trigger
    Deref
    Exit

  ThreadSignal* = object
    case kind*: ThreadSignalKind
    of Call:
      slot*: AgentProc
      req*: SigilRequest
      tgt*: WeakRef[Agent]
    of Move:
      item*: Agent
    of Trigger:
      discard
    of Deref:
      deref*: WeakRef[Agent]
    of Exit:
      discard

  SigilChan* = Chan[ThreadSignal]

  AgentRemote* = ref object of Agent
    inbox*: Chan[ThreadSignal]

  ThreadAgent* = ref object of Agent

  SigilThread* = object of RootObj
    threadId*: Atomic[int]

    signaledLock*: Lock
    signaled*: HashSet[WeakRef[AgentRemote]]
    references*: Table[WeakRef[Agent], Agent]
    agent*: ThreadAgent
    exceptionHandler*: proc(e: ref Exception) {.gcsafe, nimcall.}
    when defined(sigilsDebug):
      debugName*: string
    running*: Atomic[bool]
    toCancel*: HashSet[SigilTimer]

  SigilThreadDefault* = object of SigilThread
    inputs*: SigilChan
    thr*: Thread[ptr SigilThread]
  
  SigilThreadPtr* = ptr SigilThread
  SigilThreadDefaultPtr* = ptr SigilThreadDefault

proc timeout*(timer: SigilTimer) {.signal.}

proc getThreadId*(thread: SigilThread): int =
  addr(thread.threadId)[].load(Relaxed)

proc repr*(obj: SigilThread): string =
  when defined(sigilsDebug):
    let dname = "name: " & obj.debugName & ", "
  else:
    let dname = ""

  result =
    fmt"SigilThread(id: {$getThreadId(obj)}, {dname}signaled: {$obj.signaled.len} agent: {$obj.agent.unsafeWeakRef} )"


proc `=destroy`*(thread: var SigilThread) =
  # SigilThread
  thread.running.store(false, Relaxed)

proc newSigilChan*(): SigilChan =
  result = newChan[ThreadSignal](1_000)

method send*(
    thread: SigilThreadPtr, msg: sink ThreadSignal, blocking: BlockingKinds = Blocking
) {.base, gcsafe.} =
  raise newException(AssertionDefect, "this should never be called!")

method recv*(
    thread: SigilThreadPtr, msg: var ThreadSignal, blocking: BlockingKinds
): bool {.base, gcsafe.} =
  raise newException(AssertionDefect, "this should never be called!")

method setTimer*(
    thread: SigilThreadPtr, timer: SigilTimer
) {.base, gcsafe.} =
  raise newException(AssertionDefect, "this should never be called!")

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

var localSigilThread {.threadVar.}: ptr SigilThread

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

proc toSigilThread*[R: SigilThread](t: ptr R): ptr SigilThread =
  cast[ptr SigilThread](t)

proc hasLocalSigilThread*(): bool =
  not localSigilThread.isNil

proc setLocalSigilThread*[R: SigilThread](thread: ptr R) =
  localSigilThread = thread.toSigilThread()

proc hasCancelTimer*(thread: SigilThreadPtr, timer: SigilTimer): bool =
  timer in thread.toCancel

proc cancelTimer*(thread: SigilThreadPtr, timer: SigilTimer) =
  thread.toCancel.incl(timer)

proc startLocalThread*() =
  if not hasLocalSigilThread():
    var st = newSigilThread()
    st[].threadId.store(getThreadId(), Relaxed)
    setLocalSigilThread(st)

proc getCurrentSigilThread*(): SigilThreadPtr =
  if not hasLocalSigilThread():
    startLocalThread()
  assert hasLocalSigilThread()
  return localSigilThread

proc gcCollectReferences(thread: SigilThreadPtr) =
  var derefs: seq[WeakRef[Agent]]
  for agent in thread.references.keys():
    if not agent[].hasConnections():
      derefs.add(agent)
  for agent in derefs:
    debugPrint "\tderef cleanup: ", agent.unsafeWeakRef()
    thread.references.del(agent)

proc exec*(thread: SigilThreadPtr, sig: ThreadSignal) {.gcsafe.} =
  debugPrint "\nthread got request: ", $sig.kind
  case sig.kind
  of Exit:
    debugPrint "\t threadExec:exit: ", $getThreadId()
    thread.running.store(false, Relaxed)
  of Move:
    debugPrint "\t threadExec:move: ",
      $sig.item.unsafeWeakRef(), " refcount: ", $sig.item.unsafeGcCount()
    var item = sig.item
    thread.references[item.unsafeWeakRef()] = move item
  of Deref:
    debugPrint "\t threadExec:deref: ", $sig.deref.unsafeWeakRef()
    if thread.references.contains(sig.deref):
      debugPrint "\t threadExec:run:deref: ", $sig.deref.unsafeWeakRef()
      thread.references.del(sig.deref)
    withLock thread.signaledLock:
      thread.signaled.excl(cast[WeakRef[AgentRemote]](sig.deref))
    thread.gcCollectReferences()
  of Call:
    debugPrint "\t threadExec:call: ", $sig.tgt[].getSigilId()
    # for item in thread.references.items():
    #   debugPrint "\t threadExec:refcheck: ", $item.getSigilId(), " rc: ", $item.unsafeGcCount()
    when defined(sigilsDebug) or defined(debug):
      if sig.tgt[].freedByThread != 0:
        echo "exec:call:sig.tgt[].freedByThread:thread: ", $sig.tgt[].freedByThread
        echo "exec:call:sig.req: ", sig.req.repr
        echo "exec:call:thr: ", $getThreadId()
        echo "exec:call: ", $sig.tgt[].getSigilId()
        echo "exec:call:isUnique: ", sig.tgt[].isUniqueRef
        # echo "exec:call:has: ", sig.tgt[] in getCurrentSigilThread()[].references
        # discard c_raise(11.cint)
      assert sig.tgt[].freedByThread == 0
    {.cast(gcsafe).}:
      let res = sig.tgt[].callMethod(sig.req, sig.slot)
    debugPrint "\t threadExec:tgt: ",
      $sig.tgt[].getSigilId(), " rc: ", $sig.tgt[].unsafeGcCount()
  of Trigger:
    debugPrint "Triggering"
    var signaled: HashSet[WeakRef[AgentRemote]]
    withLock thread.signaledLock:
      signaled = move thread.signaled
    {.cast(gcsafe).}:
      for signaled in signaled:
        debugPrint "triggering: ", signaled
        var sig: ThreadSignal
        debugPrint "triggering:inbox: ", signaled[].inbox.repr
        while signaled[].inbox.tryRecv(sig):
          debugPrint "\t threadExec:tgt: ", $sig.tgt, " rc: ", $sig.tgt[].unsafeGcCount()
          let res = sig.tgt[].callMethod(sig.req, sig.slot)

proc started*(tp: ThreadAgent) {.signal.}

proc isRunning*(thread: SigilThreadPtr): bool =
  thread.running.load(Relaxed)

proc defaultExceptionHandler*(e: ref Exception) =
  echo "Sigil thread unhandled exception: ", e.msg, " ", e.name

proc setExceptionHandler*(
    thread: var SigilThread,
    handler: proc(e: ref Exception) {.gcsafe, nimcall.}
) =
  thread.exceptionHandler = handler

proc poll*(thread: SigilThreadPtr) =
  var sig: ThreadSignal
  discard thread.recv(sig, Blocking)
  thread.exec(sig)

proc tryPoll*(thread: SigilThreadPtr) =
  var sig: ThreadSignal
  if thread.recv(sig, NonBlocking):
    thread.exec(sig)

proc pollAll*(thread: SigilThreadPtr): int {.discardable.} =
  var sig: ThreadSignal
  result = 0
  while thread.recv(sig, NonBlocking):
    thread.exec(sig)
    result.inc()

proc runForever*[R: SigilThreadPtr](thread: R) =
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

proc runThread*(thread: SigilThreadPtr) {.thread.} =
  {.cast(gcsafe).}:
    pcnt.inc
    pidx = pcnt
    assert localSigilThread.isNil()
    localSigilThread = thread.toSigilThread()
    thread[].threadId.store(getThreadId(), Relaxed)
    debugPrint "Sigil worker thread waiting!"
    thread.runForever()

proc start*(thread: SigilThreadDefaultPtr) =
  if thread[].exceptionHandler.isNil:
    thread[].exceptionHandler = defaultExceptionHandler
  createThread(thread[].thr, runThread, thread)

proc stop*(thread: SigilThreadDefaultPtr, immediate: bool = false) =
  if immediate:
    thread[].running.store(false, Relaxed)
  else:
    thread.send(ThreadSignal(kind: Exit))

proc join*(thread: SigilThreadDefaultPtr) =
  doAssert not thread.isNil()
  thread[].thr.joinThread()

proc peek*(thread: SigilThreadDefaultPtr): int =
  result = thread[].inputs.peek()

proc newTimer*(duration: Duration, repeat: int = -1): SigilTimer =
  result = SigilTimer()
  result.duration = duration
  result.repeat = repeat
