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

  AsyncAgentProxy*[T] = ref object of AsyncAgentProxyShared

  SigilAsyncThread* = ref object of Agent
    thread*: Thread[Chan[ThreadSignal]]
    inputs*: Chan[ThreadSignal]


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
