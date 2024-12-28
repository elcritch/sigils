import std/tables
import std/sets
import std/hashes
import threading/smartptrs
import threading/channels
import std/unittest

type WeakRef*[T] {.acyclic.} = object
  pt* {.cursor.}: T

template `[]`*[T](r: WeakRef[T]): lent T =
  cast[T](r.pt)

proc toPtr*[T](obj: WeakRef[T]): pointer =
  result = cast[pointer](obj.pt)

proc toRef*[T: ref](obj: WeakRef[T]): T =
  result = cast[T](obj)

proc toRef*[T: ref](obj: T): T =
  result = obj

type
  AgentObj = object of RootObj
    subscribers*: Table[int, int] ## agents listening to me
    when defined(debug):
      freed*: bool
      moved*: bool

  Agent* = ref object of AgentObj

  AgentProc* = proc(context: Agent, params: string) {.nimcall.}

  AgentProxyShared* {.acyclic.} = ref object of Agent
    remote*: WeakRef[Agent]

  AgentProxy*[T] = ref object of AgentProxyShared

proc `=destroy`*(agent: AgentObj) =
  let xid: WeakRef[Agent] = WeakRef[Agent](pt: cast[pointer](addr agent))

  echo "\ndestroy: agent: ",
          " pt: ", xid.toPtr.repr,
          " freed: ", agent.freed,
          " moved: ", agent.moved,
          " lstCnt: ", xid[].subscribers.len(),
          " (th: ", getThreadId(), ")"
  when defined(debug):
    if agent.moved:
      raise newException(Defect, "moved!")
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