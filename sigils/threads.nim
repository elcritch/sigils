import std/sets
import std/isolation
import agents
import threading/smartptrs
import threading/channels

export channels, smartptrs

type
  SigilsThread* = ref object of Agent
    thread*: Thread[Chan[AgentRequest]]
    inputs*: Chan[AgentRequest]

  AgentRouter* = ref object of Agent
    remote*: SharedPtr[Agent]
    chan*: Chan[AgentRequest]

  AgentProxy*[T] = ref object of AgentRouter

proc newSigilsThread*(): SigilsThread =
  result = SigilsThread()
  result.inputs = newChan[AgentRequest]()

proc runThread*(inputs: Chan[AgentRequest]) =
  echo "sigil thread waiting!"
  while true:
    let req = inputs.recv()
    echo "thread got request: ", req

proc start*(thread: SigilsThread) =
  createThread(thread.thread, runThread, thread.inputs)


proc moveToThread*[T: Agent](agent: T, thread: SigilsThread): AgentProxy[T] =

  if not isUniqueRef(agent):
    raise newException(AccessViolationDefect,
            "agent must be unique and not shared to be passed to another thread!")
  
  return AgentProxy[T](
    remote: newSharedPtr(unsafeIsolate(Agent(agent))),
    chan: thread.inputs
  )

template connect*[T, S](
    a: Agent,
    signal: typed,
    b: AgentProxy[T],
    slot: Signal[S],
    acceptVoidSlot: static bool = false,
): void =
  ## connects `AgentProxy[T]` to remote signals
  ## 
  checkSignalTypes(a, signal, T(), slot, acceptVoidSlot)
  a.addAgentListeners(signalName(signal), b, slot)

template connect*[T](
    a: Agent,
    signal: typed,
    b: AgentProxy[T],
    slot: typed,
    acceptVoidSlot: static bool = false,
): void =
  ## connects `AgentProxy[T]` to remote signals
  ## 
  let agentSlot = `slot`(T)
  checkSignalTypes(a, signal, T(), agentSlot, acceptVoidSlot)
  a.addAgentListeners(signalName(signal), b, agentSlot)

# except ConversionError as err:
#   result = wrapResponseError(
#               req.id,
#               INVALID_PARAMS,
#               req.procName & " raised an exception",
#               err,
#               true)
# except CatchableError as err:
#   result = wrapResponseError(
#               req.id,
#               INTERNAL_ERROR,
#               req.procName & " raised an exception: " & err.msg,
#               err,
#               true)