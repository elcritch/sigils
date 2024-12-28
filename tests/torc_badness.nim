import std/tables
import threading/smartptrs
import threading/channels
import std/unittest

type WeakRef*[T] {.acyclic.} = object
  pt* {.cursor.}: T # cursor effectively is just a pointer

proc `=trace`[T](dest: var WeakRef[T]; env: pointer) =
  discard

proc `=destroy`*[T](agentObj: WeakRef[T]) =
  discard

template `[]`*[T](r: WeakRef[T]): lent T =
  ## using this in the destructor is fine because it's lent
  cast[T](r.pt)

proc toRef*[T: ref](obj: WeakRef[T]): T =
  ## using this in the destructor breaks ORC
  result = cast[T](obj)

type
  AgentObj = object of RootObj
    subscribers*: Table[int, WeakRef[Agent]] ## agents listening to me
    when defined(debug):
      freed*: bool
      moved*: bool

  Agent* = ref object of AgentObj

proc `=wasMoved`(agent: var AgentObj) =
  echo "agent was moved"
  agent.moved = true

proc `=destroy`*(agentObj: AgentObj) =
  let xid: WeakRef[Agent] = WeakRef[Agent](pt: cast[Agent](addr agentObj)) ##\
    ## This is pretty hacky, but we need to get the address of the original
    ## Agent (ref object) since it's used to unsubscribe from other agents in the actual code,
    ## Luckily the agent address is the same as `addr agent` of the agent object here.
  echo "destroying agent: ",
          " pt: ", cast[pointer](xid.pt).repr,
          " freed: ", agentObj.freed,
          " moved: ", agentObj.moved,
          " lstCnt: ", xid[].subscribers.len()
  when defined(debug):
    if agentObj.freed:
      raise newException(Defect, "already freed!")

  xid[].freed = true

  ## remove subscribers via their WeakRef's
  ## this is where we create a problem
  ## by using `toRef` which creates a *new* Agent reference
  ## which gets added to ORC as a potential cycle check (?)
  when defined(breakOrc):
    if xid.toRef().subscribers.len() > 0:
      echo "has subscribers"
  else:
    if xid[].subscribers.len() > 0:
      echo "has subscribers"

  `=destroy`(xid[].subscribers)
  echo "finished destroy: agent: ", " pt: ", cast[pointer](xid.pt).repr

type
  Counter* = ref object of Agent
    value: int

suite "threaded agent slots":
  test "sigil object thread runner":

    block:
      var b = Counter.new()
    
    GC_fullCollect()