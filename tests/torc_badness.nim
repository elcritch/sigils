## torc_badness.nim
import std/tables
import std/unittest

type WeakRef*[T] {.acyclic.} = object
  pt* {.cursor.}: T # cursor effectively is just a pointer, also happens w/ pointer type

template `[]`*[T](r: WeakRef[T]): lent T =
  ## using this in the destructor is fine because it's lent
  cast[T](r.pt)

proc toRef*[T: ref](obj: WeakRef[T]): T =
  ## using this in the destructor breaks ORC
  result = cast[T](obj)

type
  AgentObj = object of RootObj
    subcriptionsTable*: Table[int, WeakRef[Agent]] ## agents listening to me
    freedByThread*: int

  Agent* = ref object of AgentObj
  # Agent* {.acyclic.} = ref object of AgentObj ## this also avoids the issue

# proc `=wasMoved`(agent: var AgentObj) =
#   echo "agent was moved"
#   agent.moved = true

proc `=destroy`*(agentObj: AgentObj) =
  let xid: WeakRef[Agent] = WeakRef[Agent](pt: cast[Agent](addr agentObj)) ##\
    ## This is pretty hacky, but we need to get the address of the original
    ## Agent (ref object) since it's used to unsubscribe from other agents in the actual code,
    ## Luckily the agent address is the same as `addr agent` of the agent object here.
  echo "Destroying agent: ",
          " pt: ", cast[pointer](xid.pt).repr,
          " freed: ", agentObj.freedByThread,
          " lstCnt: ", xid[].subcriptionsTable.len()
  if agentObj.freedByThread != 0:
    raise newException(Defect, "already freed!")

  xid[].freedByThread = getThreadId()

  ## remove subcriptionsTable via their WeakRef's
  ## this is where we create a problem
  ## by using `toRef` which creates a *new* Agent reference
  ## which gets added to ORC as a potential cycle check (?)
  ## adding `{.acyclic.}` to 
  when defined(breakOrc):
    if xid.toRef().subcriptionsTable.len() > 0:
      echo "has subcriptionsTable"
  else:
    if xid[].subcriptionsTable.len() > 0:
      echo "has subcriptionsTable"

  `=destroy`(xid[].subcriptionsTable)
  echo "finished destroy: agent: ", " pt: 0x", cast[pointer](xid.pt).repr

type
  Counter* = ref object of Agent
    value: int

suite "threaded agent slots":
  test "sigil object thread runner":

    block:
      var b = Counter.new()
    
    GC_fullCollect()
