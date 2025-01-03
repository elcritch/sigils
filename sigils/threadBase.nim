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
  # SigilChanRef* = ref object of RootObj
  #   ch*: Chan[ThreadSignal]

  # SigilChan* = SharedPtr[SigilChanRef]

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
    references*: HashSet[Agent]

  SigilThreadRegular* = ref object of SigilThreadBase
    thr*: Thread[SharedPtr[SigilThreadRegular]]

  SigilThread* = SharedPtr[SigilThreadRegular]

var localSigilThread {.threadVar.}: Option[SigilThread]

proc newSigilChan*(): SigilChan =
  # let cref = SigilChanRef.new()
  # GC_ref(cref)
  # result = newSharedPtr(unsafeIsolate cref)
  # result[].ch = newChan[ThreadSignal](1_000)
  result = newChan[ThreadSignal](1_000)


# method trySend*(chan: SigilChanRef, msg: sink Isolated[ThreadSignal]): bool {.gcsafe, base.} =
#   # debugPrint &"chan:trySend:"
#   result = chan[].ch.trySend(msg)
#   # debugPrint &"chan:trySend: res: {$result}"

# method send*(chan: SigilChanRef, msg: sink Isolated[ThreadSignal]) {.gcsafe, base.} =
#   # debugPrint "chan:send: "
#   chan[].ch.send(msg)

# method tryRecv*(chan: SigilChanRef, dst: var ThreadSignal): bool {.gcsafe, base.} =
#   # debugPrint "chan:tryRecv:"
#   result = chan[].ch.tryRecv(dst)

# method recv*(chan: SigilChanRef): ThreadSignal {.gcsafe, base.} =
#   # debugPrint "chan:recv: "
#   chan[].ch.recv()

proc remoteSlot*(context: Agent, params: SigilParams) {.nimcall.} =
  raise newException(AssertionDefect, "this should never be called!")
proc localSlot*(context: Agent, params: SigilParams) {.nimcall.} =
  raise newException(AssertionDefect, "this should never be called!")

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

proc exec*[R: SigilThreadBase](thread: var R, sig: ThreadSignal) =
  debugPrint "\nthread got request: ", $sig
  case sig.kind:
  of Move:
    debugPrint "\t threadExec:move: ", $sig.item.getId(), " refcount: ", $sig.item.unsafeGcCount()
    var item = sig.item
    thread.references.incl(item)
  of Deref:
    debugPrint "\t threadExec:deref: ", $sig.deref, " refcount: ", $sig.deref[].unsafeGcCount()
    if not sig.deref[].isNil:
      # GC_unref(sig.deref[])
      thread.references.excl(sig.deref[])
    var derefs: seq[Agent]
    for agent in thread.references:
      if not agent.hasConnections():
        derefs.add(agent)
    for agent in derefs:
      debugPrint "\tderef cleanup: ", agent.unsafeWeakRef()
      thread.references.excl(agent)

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
        debugPrint "\t threadExec:tgt: ", $sig.tgt[].getId(), " rc: ", $sig.tgt[].unsafeGcCount()
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

proc findSubscribedToSignals(
    listening: HashSet[WeakRef[Agent]], xid: WeakRef[Agent]
): Table[SigilName, OrderedSet[Subscription]] =
  ## remove myself from agents I'm subscribed to
  for obj in listening:
    debugPrint "freeing subscribed: ", $obj[].getId()
    var toAdd = initOrderedSet[Subscription]()
    for signal, subscriberPairs in obj[].subcriptionsTable.mpairs():
      for item in subscriberPairs:
        if item.tgt == xid:
          toAdd.incl(Subscription(tgt: obj, slot: item.slot))
          # echo "agentRemoved: ", "tgt: ", xid.toPtr.repr, " id: ", agent.debugId, " obj: ", obj[].debugId, " name: ", signal
      result[signal] = move toAdd
