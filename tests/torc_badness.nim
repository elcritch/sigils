import std/tables
import std/sets
import std/hashes
import threading/smartptrs
import threading/channels
import std/unittest

type WeakRef*[T] {.acyclic.} = object
  # pt* {.cursor.}: T
  pt*: pointer


template `[]`*[T](r: WeakRef[T]): lent T =
  cast[T](r.pt)

proc toPtr*[T](obj: WeakRef[T]): pointer =
  result = cast[pointer](obj.pt)

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

proc `=destroy`*(agent: AgentObj) =
  let xid: WeakRef[Agent] = WeakRef[Agent](pt: cast[pointer](addr agent))

  echo "\ndestroy: agent: ",
          " pt: ", xid.toPtr.repr,
          " freed: ", agent.freed,
          " moved: ", agent.moved,
          " lstCnt: ", xid[].subscribers.len(),
          " subscribedTo: ", xid[].subscribedTo.len(),
          " (th: ", getThreadId(), ")"
  when defined(debug):
    if agent.moved:
      raise newException(Defect, "moved!")
    echo "destroy: agent: ", agent.moved, " freed: ", agent.freed
    if agent.freed:
      raise newException(Defect, "already freed!")

  xid[].freed = true
  # if xid[].subscribers.len() > 0:
  #   echo "has subscribers"
  if xid.toRef().subscribers.len() > 0:
    echo "has subscribers"

  `=destroy`(xid[].subscribers)
  echo "finished destroy: agent: ", " pt: ", xid.toPtr.repr

proc moveToThread*[T: Agent](
    agentTy: T,
): AgentProxy[T] =
  if not isUniqueRef(agentTy):
    raise newException(
      AccessViolationDefect,
      "agent must be unique and not shared to be passed to another thread!",
    )
  let
    proxy = AgentProxy[T](
    )

type
  Counter* = ref object of Agent
    value: int

suite "threaded agent slots":
  test "sigil object thread runner":

    block:
      var
        b = Counter.new()
      echo "thread runner!", " (th: ", getThreadId(), ")"
      let bp: AgentProxy[Counter] = b.moveToThread()
    
    GC_fullCollect()