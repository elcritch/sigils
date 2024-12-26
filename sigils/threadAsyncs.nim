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

type
  AsyncAgentProxy*[T] = ref object of AgentProxy[T]
    event*: AsyncEvent

  AsyncSigilThreadObj* = object of Agent
    thread*: Thread[(AsyncEvent, Chan[ThreadSignal])]
    inputs*: Chan[ThreadSignal]
    event*: AsyncEvent

  AsyncSigilThread* = SharedPtr[AsyncSigilThreadObj]

proc moveToThread*[T: Agent](agent: T, thread: AsyncSigilThread): AgentProxy[T] =
  if not isUniqueRef(agent):
    raise newException(
      AccessViolationDefect,
      "agent must be unique and not shared to be passed to another thread!",
    )

  let proxy = AsyncAgentProxy[T](
    remote: newSharedPtr(unsafeIsolate(Agent(agent))),
    outbound: thread[].inputs,
    event: thread[].event,
  )
  return AgentProxy[T](proxy)

method callMethod*[T](
    ctx: AsyncAgentProxy[T], req: SigilRequest, slot: AgentProc
): SigilResponse {.gcsafe, effectsOf: slot.} =
  ## Route's an rpc request. 
  # echo "threaded Agent!"
  let proxy = ctx
  let sig = ThreadSignal(slot: slot, req: req, tgt: proxy.remote)
  # echo "executeRequest:asyncAgentProxy: ", "chan: ", $proxy.chan
  let res = proxy.chan.trySend(unsafeIsolate sig)
  proxy.event.trigger()
  if not res:
    raise newException(AgentSlotError, "error sending signal to thread")

proc newSigilAsyncThread*(): AsyncSigilThread =
  result = newSharedPtr(AsyncSigilThreadObj())
  result[].inputs = newChan[ThreadSignal]()
  result[].event = newAsyncEvent()

proc asyncExecute*(inputs: Chan[ThreadSignal]) =
  while true:
    echo "asyncExecute..."
    # proc addEvent(ev: AsyncEvent; cb: Callback)
    poll(inputs)

proc asyncExecute*(thread: AsyncSigilThread) =
  thread[].inputs.asyncExecute()

proc runAsyncThread*(args: (AsyncEvent, Chan[ThreadSignal])) {.thread.} =
  var
    event: AsyncEvent = args[0]
    inputs = args[1]
  echo "sigil thread waiting!", " (", getThreadId(), ")"

  let cb = proc(fd: AsyncFD): bool {.closure, gcsafe.} =
    {.cast(gcsafe).}:
      var sig: ThreadSignal
      if inputs.tryRecv(sig):
        echo "async thread run: "
        discard sig.tgt[].callMethod(sig.req, sig.slot)

  event.addEvent(cb)
  runForever()

proc start*(thread: AsyncSigilThread) =
  let args = (thread[].event, thread[].inputs)
  createThread(thread[].thread, runAsyncThread, args)
