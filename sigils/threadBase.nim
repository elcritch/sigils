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

const SigilTimerRepeat* = -1

type
  SigilTimer* = ref object of Agent
    duration*: Duration
    count*: int = SigilTimerRepeat # -1 for repeat forever, N > 0 for N times

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

  SigilThreadPtr* = ptr SigilThread

proc timeout*(timer: SigilTimer) {.signal.}

proc started*(tp: ThreadAgent) {.signal.}

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

method poll*(
    thread: SigilThreadPtr, blocking: BlockingKinds = Blocking
): bool {.base, gcsafe, discardable.} =
  raise newException(AssertionDefect, "this should never be called!")

proc isRunning*(thread: SigilThreadPtr): bool =
  thread.running.load(Relaxed)

proc setRunning*(thread: SigilThreadPtr, state: bool, immediate = false) =
  if immediate:
    thread[].running.store(state, Relaxed)
  else:
    thread.send(ThreadSignal(kind: Exit))

proc gcCollectReferences(thread: SigilThreadPtr) =
  var derefs: seq[WeakRef[Agent]]
  for agent in thread.references.keys():
    if not agent[].hasConnections():
      derefs.add(agent)
  for agent in derefs:
    debugPrint "\tderef cleanup: ", agent.unsafeWeakRef()
    thread.references.del(agent)

proc exec*(thread: SigilThreadPtr, sig: ThreadSignal) {.gcsafe.} =
  ## Handles the core of the Sigils multi-threading using a thread safe
  ## design that's safe with non-atomic ref-counts.
  ##
  ## It works in several stages that all work through this proc that executes
  ## commands from either side of the "command" queue:
  ##
  ## 1. `Move` message: moves an object to the remote thread when a proxy is made
  ## 2. `Trigger` message: executes calls on signaled objects
  ## 3. `Deref` message: decr the ref count - will free remote object without thread-local refs 
  ## 4. `Exit` message: executes calls on signaled objects
  ##
  ## As an alternative to Trigger a call can be executed directly but is normally
  ## used for local queued connections rather than remote ones.
  ##
  ## 5. `Call` message: used for local calls - immediately calls
  ##
  debugPrint "\nthread got request: ", $sig.kind
  case sig.kind
  of Move:
    var item = sig.item
    thread.references[item.unsafeWeakRef()] = move item
  of Trigger:
    var signaled: HashSet[WeakRef[AgentRemote]]
    withLock thread.signaledLock:
      signaled = move thread.signaled
    # loop and execute calls for all triggered agents
    for signaled in signaled:
      var sig: ThreadSignal
      while signaled[].inbox.tryRecv(sig):
        {.cast(gcsafe).}:
          discard sig.tgt[].callMethod(sig.req, sig.slot)
  of Call:
    {.cast(gcsafe).}:
      discard sig.tgt[].callMethod(sig.req, sig.slot)
  of Deref:
    if thread.references.contains(sig.deref):
      thread.references.del(sig.deref)
    withLock thread.signaledLock:
      thread.signaled.excl(cast[WeakRef[AgentRemote]](sig.deref))
    thread.gcCollectReferences()
  of Exit:
    thread.running.store(false, Relaxed)

proc runForever*(thread: SigilThreadPtr) {.gcsafe.} =
  emit thread.agent.started()
  while thread.isRunning():
    try:
      discard thread.poll()
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

proc pollAll*(thread: SigilThreadPtr, blocking: BlockingKinds = NonBlocking): int {.discardable.} =
  var sig: ThreadSignal
  result = 0
  while thread.poll(blocking):
    result.inc()

proc defaultExceptionHandler*(e: ref Exception) =
  echo "Sigil thread unhandled exception: ", e.msg, " ", e.name
  echo "Sigil thread unhandled stack trace: ", e.getStackTrace()

proc setExceptionHandler*(
    thread: var SigilThread,
    handler: proc(e: ref Exception) {.gcsafe, nimcall.}
) =
  thread.exceptionHandler = handler

var startSigilThreadProc: proc()
var localSigilThread {.threadVar.}: ptr SigilThread

proc toSigilThread*[R: SigilThread](t: ptr R): ptr SigilThread =
  cast[ptr SigilThread](t)

proc hasLocalSigilThread*(): bool =
  not localSigilThread.isNil

proc setLocalSigilThread*[R: ptr SigilThread](thread: R) =
  localSigilThread = thread.toSigilThread()

proc setStartSigilThreadProc*(cb: proc()) =
  startSigilThreadProc = cb

proc getStartSigilThreadProc*(): proc() =
  startSigilThreadProc

template getCurrentSigilThread*(): SigilThreadPtr =
  if not hasLocalSigilThread():
    doAssert not startSigilThreadProc.isNil, "startSigilThreadProc is not set!"
    startSigilThreadProc()
  doAssert hasLocalSigilThread()
  localSigilThread

## Timer API
proc hasCancelTimer*(thread: SigilThreadPtr, timer: SigilTimer): bool =
  timer in thread.toCancel

proc cancelTimer*(thread: SigilThreadPtr, timer: SigilTimer) =
  thread.toCancel.incl(timer)

proc removeTimer*(thread: SigilThreadPtr, timer: SigilTimer) =
  thread.toCancel.excl(timer)

proc newSigilTimer*(duration: Duration, count: int = SigilTimerRepeat): SigilTimer =
  result = SigilTimer()
  result.duration = duration
  result.count = count

proc isRepeat*(timer: SigilTimer): bool =
  timer.count == SigilTimerRepeat

proc start*(timer: SigilTimer, ct: SigilThreadPtr = getCurrentSigilThread()) =
  ct.setTimer(timer)

proc cancel*(timer: SigilTimer, ct: SigilThreadPtr = getCurrentSigilThread()) =
  ct.cancelTimer(timer)
