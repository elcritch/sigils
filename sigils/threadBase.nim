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

  SigilThreadBase* = ref object of Agent
    id*: int
    inputs*: SigilChan

    signaledLock*: Lock
    signaled*: HashSet[WeakRef[AgentRemote]]
    references*: HashSet[WeakRef[Agent]]

  SigilThreadRegular* = ref object of SigilThreadBase
    thr*: Thread[SharedPtr[SigilThreadRegular]]

  SigilThread* = SharedPtr[SigilThreadRegular]

var localSigilThread {.threadVar.}: Option[SigilThread]

proc newSigilChan*(): SigilChan =
  result = newChan[ThreadSignal](1_000)

proc newSigilThread*(): SigilThread =
  result = newSharedPtr(isolate SigilThreadRegular())
  result[].inputs = newSigilChan()

proc startLocalThread*() =
  if localSigilThread.isNone:
    localSigilThread = some newSigilThread()
    localSigilThread.get()[].id = getThreadId()

proc getCurrentSigilThread*(): SigilThread =
  startLocalThread()
  return localSigilThread.get()

proc gcCollectReferences(thread: SigilThreadBase) =
  var derefs: seq[WeakRef[Agent]]
  for agent in thread.references:
    if not agent[].hasConnections():
      derefs.add(agent)
  for agent in derefs:
    debugPrint "\tderef cleanup: ", agent.unsafeWeakRef()
    thread.references.excl(agent)
    GC_unref(agent[])

proc exec*[R: SigilThreadBase](thread: var R, sig: ThreadSignal) =
  debugPrint "\nthread got request: ", $sig.kind
  case sig.kind:
  of Move:
    debugPrint "\t threadExec:move: ", $sig.item.unsafeWeakRef(), " refcount: ", $sig.item.unsafeGcCount()
    var item = sig.item
    GC_ref(item)
    thread.references.incl(item.unsafeWeakRef())
  of Deref:
    debugPrint "\t threadExec:deref: ", $sig.deref.unsafeWeakRef()
    if thread.references.contains(sig.deref):
      thread.references.excl(sig.deref)
      GC_unref(sig.deref[])
    thread.gcCollectReferences()
  of Call:
    debugPrint "\t threadExec:call: ", $sig.tgt[].getId()
    # for item in thread.references.items():
    #   debugPrint "\t threadExec:refcheck: ", $item.getId(), " rc: ", $item.unsafeGcCount()
    when defined(sigilsDebug) or defined(debug):
      if sig.tgt[].freedByThread != 0:
        echo "exec:call:sig.tgt[].freedByThread:thread: ", $sig.tgt[].freedByThread
        echo "exec:call:sig.req: ", sig.req.repr
        echo "exec:call:thr: ", $getThreadId()
        echo "exec:call: ", $sig.tgt[].getId()
        echo "exec:call:isUnique: ", sig.tgt[].isUniqueRef
        # echo "exec:call:has: ", sig.tgt[] in getCurrentSigilThread()[].references
        # discard c_raise(11.cint)
      assert sig.tgt[].freedByThread == 0
    let res = sig.tgt[].callMethod(sig.req, sig.slot)
    debugPrint "\t threadExec:tgt: ", $sig.tgt[].getId(), " rc: ", $sig.tgt[].unsafeGcCount()
  of Trigger:
    debugPrint "Triggering"
    var signaled: HashSet[WeakRef[AgentRemote]]
    withLock thread.signaledLock:
      signaled = move thread.signaled
    for signaled in signaled:
      debugPrint "triggering: ", signaled
      var sig: ThreadSignal
      while signaled[].inbox.tryRecv(sig):
        debugPrint "\t threadExec:tgt: ", $sig.tgt, " rc: ", $sig.tgt[].unsafeGcCount()
        let res = sig.tgt[].callMethod(sig.req, sig.slot)

proc started*(tp: SigilThreadBase) {.signal.}

proc poll*[R: SigilThreadBase](thread: var R) =
  let sig = thread.inputs.recv()
  thread.exec(sig)

proc tryPoll*[R: SigilThreadBase](thread: var R) =
  var sig: ThreadSignal
  if thread.inputs.tryRecv(sig):
    thread.exec(sig)

proc pollAll*[R: SigilThreadBase](thread: var R): int {.discardable.} =
  var sig: ThreadSignal
  result = 0
  while thread.inputs.tryRecv(sig):
    thread.exec(sig)
    result.inc()

proc runForever*(thread: SigilThread) =
  emit thread[].started()
  while true:
    thread[].poll()

proc runThread*(thread: SigilThread) {.thread.} =
  {.cast(gcsafe).}:
    pcnt.inc
    pidx = pcnt
    assert localSigilThread.isNone()
    localSigilThread = some(thread)
    thread[].id = getThreadId()
    debugPrint "Sigil worker thread waiting!"
    thread.runForever()

proc start*(thread: SigilThread) =
  createThread(thread[].thr, runThread, thread)
