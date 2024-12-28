import std/tables
import std/sets
import std/hashes
import threading/smartptrs
import threading/channels
import std/unittest

type WeakRef*[T] {.acyclic.} = object
  # pt* {.cursor.}: T
  pt*: pointer
  ## type alias descring a weak ref that *must* be cleaned
  ## up when an object is set to be destroyed

proc `=destroy`*[T](obj: WeakRef[T]) =
  discard

template `[]`*[T](r: WeakRef[T]): lent T =
  cast[T](r.pt)

proc toPtr*[T](obj: WeakRef[T]): pointer =
  result = cast[pointer](obj.pt)

proc hash*[T](obj: WeakRef[T]): Hash =
  result = hash cast[pointer](obj.pt)

proc toRef*[T: ref](obj: WeakRef[T]): T =
  result = cast[T](obj)

proc toRef*[T: ref](obj: T): T =
  result = obj

type
  SigilName = array[48, char]

  Subscription* = object
    tgt*: WeakRef[Agent]
    slot*: AgentProc

  AgentObj = object of RootObj
    subscribers*: Table[SigilName, OrderedSet[Subscription]] ## agents listening to me
    subscribedTo*: HashSet[WeakRef[Agent]] ## agents I'm listening to
    when defined(debug):
      freed*: bool
      moved*: bool

  Agent* = ref object of AgentObj

  AgentProc* = proc(context: Agent, params: string) {.nimcall.}

  ThreadSignalKind* {.pure.} = enum
    Call
    Move
    Deref

  ThreadSignal* = object
    case kind*: ThreadSignalKind
    of Call:
      slot*: AgentProc
      req*: string
      tgt*: WeakRef[Agent]
    of Move:
      item*: Agent
    of Deref:
      deref*: WeakRef[Agent]

  SigilThreadBase* = object of RootObj
    inputs*: SigilChan
    references*: HashSet[Agent]

  SigilThreadObj* = object of SigilThreadBase
    thr*: Thread[SharedPtr[SigilThreadObj]]

  SigilThread* = SharedPtr[SigilThreadObj]

  SigilChanRef* = ref object of RootObj
    ch*: Chan[ThreadSignal]

  SigilChan* = SharedPtr[SigilChanRef]

  AgentProxyShared* {.acyclic.} = ref object of Agent
    remote*: WeakRef[Agent]
    outbound*: SigilChan
    inbound*: SigilChan

  AgentProxy*[T] = ref object of AgentProxyShared

proc getId*[T: Agent](a: WeakRef[T]): int =
  cast[int](a.toPtr())

proc getId*(a: Agent): int =
  cast[int](cast[pointer](a))

method removeSubscriptionsFor*(
    self: Agent, subscriber: WeakRef[Agent]
) {.base, gcsafe, raises: [].} =
  ## Route's an rpc request. 
  echo "removeSubscriptionsFor ", " self:id: ", $self.getId()
  var delSigs: seq[SigilName]
  var toDel: seq[Subscription]
  for signal, subscriptions in self.subscribers.mpairs():
    echo "removeSubscriptionsFor subs ", signal
    toDel.setLen(0)
    for subscription in subscriptions:
      if subscription.tgt == subscriber:
        toDel.add(subscription)
        # echo "agentRemoved: ", "tgt: ", xid.toPtr.repr, " id: ", agent.debugId, " obj: ", obj[].debugId, " name: ", signal
    for subscription in toDel:
      subscriptions.excl(subscription)
    if subscriptions.len() == 0:
      delSigs.add(signal)
  for sig in delSigs:
    self.subscribers.del(sig)

method unregisterSubscriber*(
    self: Agent, listener: WeakRef[Agent]
) {.base, gcsafe, raises: [].} =
  # echo "\tlisterners: ", subscriber.tgt
  # echo "\tlisterners:subscribed ", subscriber.tgt[].subscribed
  assert listener in self.subscribedTo
  self.subscribedTo.excl(listener)
  # echo "\tlisterners:subscribed ", subscriber.tgt[].subscribed

proc unsubscribe*(subscribedTo: HashSet[WeakRef[Agent]], xid: WeakRef[Agent]) =
  ## unsubscribe myself from agents I'm subscribed (listening) to
  echo "unsubscribe: ", subscribedTo.len
  for obj in subscribedTo.items():
    echo "unsubscribe:obj: ", $obj
  for obj in subscribedTo:
    obj[].removeSubscriptionsFor(xid)

template removeSubscription*(
    subscribers: var Table[SigilName, OrderedSet[Subscription]], xid: WeakRef[Agent]
) =
  ## remove myself from agents listening to me
  for signal, subscriptions in subscribers.mpairs():
    # echo "freeing signal: ", signal, " subscribers: ", subscriberPairs
    for subscription in subscriptions:
      subscription.tgt[].unregisterSubscriber(xid)

proc `=destroy`*(agent: AgentObj) =
  let xid: WeakRef[Agent] = WeakRef[Agent](pt: cast[pointer](addr agent))

  echo "\ndestroy: agent: ",
          " pt: ", xid.toPtr.repr,
          " freed: ", agent.freed,
          " moved: ", agent.moved,
          " lstCnt: ", xid[].subscribers.len(),
          " subscribedTo: ", xid[].subscribedTo.len(),
          " (th: ", getThreadId(), ")"
  echo "destroy: agent:st: ", getStackTrace()
  when defined(debug):
    # echo "destroy: agent: ", agent.moved, " freed: ", agent.freed
    if agent.moved:
      raise newException(Defect, "moved!")
    echo "destroy: agent: ", agent.moved, " freed: ", agent.freed
    if agent.freed:
      raise newException(Defect, "already freed!")

  xid[].freed = true
  if xid.toRef().subscribedTo.len() > 0:
    xid.toRef().subscribedTo.unsubscribe(xid)
  if xid.toRef().subscribers.len() > 0:
    xid.toRef().subscribers.removeSubscription(xid)

  # xid[].subscribers[].clear()
  # xid[].subscribedTo[].clear()

  `=destroy`(xid[].subscribers)
  `=destroy`(xid[].subscribedTo)
  echo "finished destroy: agent: ", " pt: ", xid.toPtr.repr

proc moveToThread*[T: Agent](
    agentTy: T,
    # thread: SharedPtr[R]
): AgentProxy[T] =
  ## move agent to another thread
  if not isUniqueRef(agentTy):
    raise newException(
      AccessViolationDefect,
      "agent must be unique and not shared to be passed to another thread!",
    )
  let
    # ct = getCurrentSigilThread()
    # agent = agentTy.unsafeWeakRef.asAgent()
    proxy = AgentProxy[T](
      # remote: agent,
      # outbound: thread[].inputs,
      # inbound: ct[].inputs,
    )

type
  Counter* = ref object of Agent
    value: int

suite "threaded agent slots":
  test "sigil object thread runner":

    # var a = SomeAction.new()

    block:
      var
        b = Counter.new()
      echo "thread runner!", " (th: ", getThreadId(), ")"
      # echo "obj a: ", a.unsafeWeakRef
      # echo "obj b: ", b.unsafeWeakRef
      # echo "obj a: ", a.getId
      echo "obj b: ", b.getId

      let bp: AgentProxy[Counter] = b.moveToThread()
      echo "obj bp: ", bp.getId
      # echo "obj bp: ", bp.unsafeWeakRef
      # echo "obj bp.remote: ", bp.remote[].unsafeWeakRef

      # connect(a, valueChanged, bp, setValue)
      # connect(bp, updated, a, SomeAction.completed())

      # emit a.valueChanged(314)
      # # thread.thread.joinThread(500)
      # # os.sleep(500)
      # let ct = getCurrentSigilThread()
      # ct[].poll()
      # check a.value == 314
    
    # check a.subscribers.len() == 0
    # check a.subscribedTo.len() == 0
    GC_fullCollect()