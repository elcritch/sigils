import std/sets
import std/isolation
import std/options
import std/locks
import threading/smartptrs
import threading/channels

import isolateutils
import agents
import core

from system/ansi_c import c_raise

export smartptrs, isolation, channels
export isolateutils

type
  BlockingKinds* {.pure.} = enum
    Blocking
    NonBlocking

  ThreadSignalKind* {.pure.} = enum
    Call
    Move
    Trigger
    Deref

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

  SigilChan* = Chan[ThreadSignal]

  AgentRemote* = ref object of Agent
    inbox*: Chan[ThreadSignal]

  ThreadAgent* = ref object of Agent

  SigilThread* = object of RootObj
    id*: int

    signaledLock*: Lock
    signaled*: HashSet[WeakRef[AgentRemote]]
    references*: Table[WeakRef[Agent], Agent]
    agent*: ThreadAgent
    when defined(sigilsDebug):
      debugName*: string

  SigilThreadImpl* = object of SigilThread
    inputs*: SigilChan
    thr*: Thread[ptr SigilThread]

proc repr*(obj: SigilThread): string =
  when defined(sigilsDebug):
    let dname = "name: " & obj.debugName & ", "
  else:
    let dname = ""

  result =
    fmt"SigilThread(id: {$obj.id}, {dname}signaled: {$obj.signaled.len} agent: {$obj.agent.unsafeWeakRef} )"

proc newSigilChan*(): SigilChan =
  result = newChan[ThreadSignal](1_000)

method send*(
    thread: SigilThread, msg: sink ThreadSignal, blocking: BlockingKinds = Blocking
) {.base, gcsafe.} =
  echo "send raw!"
  raise newException(AssertionDefect, "this should never be called!")

method recv*(
    thread: SigilThread, msg: var ThreadSignal, blocking: BlockingKinds
): bool {.base, gcsafe.} =
  echo "recv raw!"
  raise newException(AssertionDefect, "this should never be called!")

method send*(
    thread: SigilThreadImpl, msg: sink ThreadSignal, blocking: BlockingKinds
) {.gcsafe.} =
  var msg = isolateRuntime(msg)
  case blocking
  of Blocking:
    thread.inputs.send(msg)
  of NonBlocking:
    let sent = thread.inputs.trySend(msg)
    if not sent:
      raise newException(Defect, "could not send!")

method recv*(
    thread: SigilThreadImpl, msg: var ThreadSignal, blocking: BlockingKinds
): bool {.gcsafe.} =
  case blocking
  of Blocking:
    msg = thread.inputs.recv()
    return true
  of NonBlocking:
    result = thread.inputs.tryRecv(msg)

var localSigilThread {.threadVar.}: ptr SigilThread

proc newSigilThread*(): ptr SigilThreadImpl =
  result = cast[ptr SigilThreadImpl](allocShared0(sizeof(SigilThreadImpl)))
  result[] = SigilThreadImpl() # important!
  result[].agent = ThreadAgent()
  result[].inputs = newSigilChan()
  result[].signaledLock.initLock()
  result[].id = -1

proc toSigilThread*[R: SigilThread](t: ptr R): ptr SigilThread =
  cast[ptr SigilThread](t)

proc startLocalThread*() =
  if localSigilThread.isNil:
    var st = newSigilThread()
    st[].id = getThreadId()
    localSigilThread = st.toSigilThread()

proc getCurrentSigilThread*(): ptr SigilThread =
  startLocalThread()
  assert not localSigilThread.isNil
  return localSigilThread

proc gcCollectReferences(thread: var SigilThread) =
  var derefs: seq[WeakRef[Agent]]
  for agent in thread.references.keys():
    if not agent[].hasConnections():
      derefs.add(agent)
  for agent in derefs:
    debugPrint "\tderef cleanup: ", agent.unsafeWeakRef()
    thread.references.del(agent)

proc exec*(thread: var SigilThread, sig: ThreadSignal) =
  debugPrint "\nthread got request: ", $sig.kind
  case sig.kind
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
    let res = sig.tgt[].callMethod(sig.req, sig.slot)
    debugPrint "\t threadExec:tgt: ",
      $sig.tgt[].getSigilId(), " rc: ", $sig.tgt[].unsafeGcCount()
  of Trigger:
    debugPrint "Triggering"
    var signaled: HashSet[WeakRef[AgentRemote]]
    withLock thread.signaledLock:
      signaled = move thread.signaled
    for signaled in signaled:
      debugPrint "triggering: ", signaled
      var sig: ThreadSignal
      debugPrint "triggering:inbox: ", signaled[].inbox.repr
      while signaled[].inbox.tryRecv(sig):
        debugPrint "\t threadExec:tgt: ", $sig.tgt, " rc: ", $sig.tgt[].unsafeGcCount()
        let res = sig.tgt[].callMethod(sig.req, sig.slot)

proc started*(tp: ThreadAgent) {.signal.}

proc poll*(thread: var SigilThread) =
  var sig: ThreadSignal
  discard thread.recv(sig, Blocking)
  thread.exec(sig)

proc tryPoll*(thread: var SigilThread) =
  var sig: ThreadSignal
  if thread.recv(sig, NonBlocking):
    thread.exec(sig)

proc pollAll*(thread: var SigilThread): int {.discardable.} =
  var sig: ThreadSignal
  result = 0
  while thread.recv(sig, NonBlocking):
    thread.exec(sig)
    result.inc()

proc runForever*[R: SigilThread](thread: var R) =
  emit thread.agent.started()
  while true:
    thread.poll()

proc runThread*(thread: ptr SigilThread) {.thread.} =
  {.cast(gcsafe).}:
    pcnt.inc
    pidx = pcnt
    assert localSigilThread.isNil()
    localSigilThread = thread.toSigilThread()
    thread[].id = getThreadId()
    debugPrint "Sigil worker thread waiting!"
    thread[].runForever()

proc start*(thread: ptr SigilThreadImpl) =
  createThread(thread[].thr, runThread, thread)
