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

  SigilThread* = ref object of Agent
    id*: int
    thr*: Thread[SharedPtr[SigilThread]]

    signaledLock*: Lock
    signaled*: HashSet[WeakRef[AgentRemote]]
    references*: Table[WeakRef[Agent], Agent]

  SigilThreadImpl* = ref object of SigilThread
    inputs*: SigilChan

var localSigilThread {.threadVar.}: Option[SharedPtr[SigilThread]]

proc newSigilChan*(): SigilChan =
  result = newChan[ThreadSignal](1_000)

method send*(thread: SigilThread, msg: sink ThreadSignal) {.base, gcsafe.} =
  discard

method recv*(thread: SigilThread, blocking: bool = true): Option[ThreadSignal] {.base, gcsafe.} =
  discard

method send*(thread: SigilThreadImpl, msg: sink ThreadSignal) {.gcsafe.} =
  var msg = isolateRuntime(msg)
  thread.inputs.send(msg)

method recv*(thread: SigilThreadImpl, blocking: bool): Option[ThreadSignal] {.gcsafe.} =
  if blocking:
    result = some thread.inputs.recv()
  else:
    var msg: ThreadSignal
    if thread.inputs.tryRecv(msg):
      result = some(msg)
    else:
      result = none[ThreadSignal]()

proc newSigilThread*(): SharedPtr[SigilThread] =
  var thr = SigilThreadImpl(inputs: newSigilChan())
  result = newSharedPtr(isolateRuntime SigilThread(thr))

proc startLocalThread*() =
  if localSigilThread.isNone:
    localSigilThread = some newSigilThread()
    localSigilThread.get()[].id = getThreadId()

proc getCurrentSigilThread*(): SharedPtr[SigilThread] =
  startLocalThread()
  return localSigilThread.get()

proc gcCollectReferences(thread: SigilThread) =
  var derefs: seq[WeakRef[Agent]]
  for agent in thread.references.keys():
    if not agent[].hasConnections():
      derefs.add(agent)
  for agent in derefs:
    debugPrint "\tderef cleanup: ", agent.unsafeWeakRef()
    thread.references.del(agent)

proc exec*[R: SigilThread](thread: var R, sig: ThreadSignal) =
  debugPrint "\nthread got request: ", $sig.kind
  case sig.kind:
  of Move:
    debugPrint "\t threadExec:move: ", $sig.item.unsafeWeakRef(), " refcount: ", $sig.item.unsafeGcCount()
    var item = sig.item
    thread.references[item.unsafeWeakRef()] = move item
  of Deref:
    debugPrint "\t threadExec:deref: ", $sig.deref.unsafeWeakRef()
    if thread.references.contains(sig.deref):
      debugPrint "\t threadExec:run:deref: ", $sig.deref.unsafeWeakRef()
      thread.references.del(sig.deref)
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

proc started*(tp: SigilThread) {.signal.}

proc poll*[R: SigilThread](thread: var R) =
  let sig = thread.recv().get()
  thread.exec(sig)

proc tryPoll*[R: SigilThread](thread: var R) =
  var sig: ThreadSignal
  if thread.inputs.tryRecv(sig):
    thread.exec(sig)

proc pollAll*[R: SigilThread](thread: var R): int {.discardable.} =
  var sig: ThreadSignal
  result = 0
  while true:
    let sig = thread.recv(blocking=false)
    if sig.isNone:
      break
    thread.exec(sig.get())
    result.inc()

proc runForever*[R: SigilThread](thread: SharedPtr[R]) =
  emit thread[].started()
  while true:
    thread[].poll()

proc runThread*(thread: SharedPtr[SigilThread]) {.thread.} =
  {.cast(gcsafe).}:
    pcnt.inc
    pidx = pcnt
    assert localSigilThread.isNone()
    localSigilThread = some(thread)
    thread[].id = getThreadId()
    debugPrint "Sigil worker thread waiting!"
    thread.runForever()

proc start*[R: SigilThread](thread: SharedPtr[R]) =
  createThread(thread[].thr, runThread, thread)
