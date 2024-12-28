import std/tables
import std/sets
import std/hashes
import threading/smartptrs
import threading/channels
import std/unittest

type WeakRef*[T] {.acyclic.} = object
  pt* {.cursor.}: T # cursor effectively is just a pointer

template `[]`*[T](r: WeakRef[T]): lent T =
  cast[T](r.pt)

proc toPtr*[T](obj: WeakRef[T]): pointer =
  result = cast[pointer](obj.pt)

proc toRef*[T: ref](obj: WeakRef[T]): T =
  result = cast[T](obj)

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

proc `=wasMoved`(agent: var AgentObj) =
  let xid: WeakRef[Agent] = WeakRef[Agent](pt: cast[Agent](addr agent))
  echo "agent was moved", " pt: ", xid.toPtr.repr
  agent.moved = true

proc `=destroy`*(agentObj: AgentObj) =
  let xid: WeakRef[Agent] = WeakRef[Agent](pt: cast[Agent](addr agentObj))
  # This is pretty hacky, but we need to get the address of the original
  # Agent ref object, which luckily is the same as `addr agent`
  # of the agent 

  echo "\ndestroy: agent: ",
          " pt: ", xid.toPtr.repr,
          " freed: ", agentObj.freed,
          " moved: ", agentObj.moved,
          " lstCnt: ", xid[].subscribers.len(),
          " (th: ", getThreadId(), ")"
  when defined(debug):
    if agentObj.moved:
      raise newException(Defect, "moved!")
    if agentObj.freed:
      raise newException(Defect, "already freed!")

  xid[].freed = true
  when defined(breakOrc):
    if xid.toRef().subscribers.len() > 0:
      echo "has subscribers"
  else:
    if xid[].subscribers.len() > 0:
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