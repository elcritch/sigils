import std/sets
import std/isolation
import threading/smartptrs
import threading/channels

import agents
import threads
import core

export channels, smartptrs, threads, isolation

import std/os
import std/monotimes
import std/options
import std/isolation
import std/uri
import std/asyncdispatch
from std/selectors import IOSelectorsException

type
  AsyncAgentProxy*[T] = ref object of AgentProxy[T]
    signal*: AsyncEvent

  AsyncSigilThread* = ref object of SigilThread
    signal*: AsyncEvent

proc moveToThread*[T: Agent](agent: T, thread: AsyncSigilThread): AgentProxy[T] =
  if not isUniqueRef(agent):
    raise newException(
      AccessViolationDefect,
      "agent must be unique and not shared to be passed to another thread!",
    )

  let proxy = AsyncAgentProxy[T](
    remote: newSharedPtr(unsafeIsolate(Agent(agent))),
    chan: thread.inputs,
    signal: thread.signal,
  )
  return AgentProxy[T](proxy)

method callMethod*[T](
    ctx: AsyncAgentProxy[T], req: SigilRequest, slot: AgentProc
): SigilResponse {.gcsafe, effectsOf: slot.} =
  ## Route's an rpc request. 
  # echo "threaded Agent!"
  let proxy = ctx
  let sig = ThreadSignal(slot: slot, req: req, tgt: proxy.remote)
  echo "executeRequest:asyncAgentProxy: ", "chan: ", $proxy.chan
  let res = proxy.chan.trySend(unsafeIsolate sig)
  proxy.signal.trigger()
  if not res:
    raise newException(AgentSlotError, "error sending signal to thread")

proc newSigilAsyncThread*(): AsyncSigilThread =
  result = AsyncSigilThread()
  result.inputs = newChan[ThreadSignal]()
  result.signal = newAsyncEvent()

proc asyncExecute*(inputs: Chan[ThreadSignal]) =
  while true:
    poll(inputs)

proc asyncExecute*(thread: AsyncSigilThread) =
  thread.inputs.asyncExecute()

proc runAsyncThread*(inputs: Chan[ThreadSignal]) {.thread.} =
  {.cast(gcsafe).}:
    var inputs = inputs
    # echo "sigil thread waiting!", " (", getThreadId(), ")"
    inputs.asyncExecute()

proc start*(thread: AsyncSigilThread) =
  createThread(thread.thread, runAsyncThread, thread.inputs)
