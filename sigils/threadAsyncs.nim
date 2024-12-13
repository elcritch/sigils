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
  AsyncAgentProxyShared* = ref object of AgentProxyShared
    trigger*: AsyncEvent

  AsyncAgentProxy*[T] = ref object of AsyncAgentProxyShared

  AsyncSigilThread* = ref object of SigilThread
    trigger*: AsyncEvent

method callMethod*(
    ctx: AgentProxyShared,
    req: SigilRequest,
    slot: AgentProc,
): SigilResponse {.gcsafe, effectsOf: slot.} =
  ## Route's an rpc request. 
  # echo "threaded Agent!"
  let proxy = ctx
  let sig = ThreadSignal(slot: slot, req: req, tgt: proxy.remote)
  # echo "executeRequest:agentProxy: ", "chan: ", $proxy.chan
  let res = proxy.chan.trySend(unsafeIsolate sig)
  if not res:
    raise newException(AgentSlotError, "error sending signal to thread")

proc newSigilAsyncThread*(): AsyncSigilThread =
  result = AsyncSigilThread()
  result.inputs = newChan[ThreadSignal]()
  result.trigger = newAsyncEvent()

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
