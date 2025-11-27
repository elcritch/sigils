import std/sets
import std/isolation
import std/locks
import threading/smartptrs
import threading/channels
import threading/atomics

import std/os
import std/options
import std/isolation
import std/selectors
import std/times
import std/tables
import std/net

import agents
import threadBase
import threadDefault
import core

export smartptrs, isolation
export threadBase

type
  SigilSelectorThread* = object of SigilThread
    inputs*: SigilChan
    sel*: Selector[SigilThreadEvent]
    drain*: Atomic[bool]
    isReady*: bool
    thr*: Thread[ptr SigilSelectorThread]
    timerLock*: Lock

  SigilSelectorThreadPtr* = ptr SigilSelectorThread

type
  SigilSocketEvent* = ref object of SigilThreadEvent
    fd*: int

  SigilSelectEvent* = ref object of SigilThreadEvent
    ## Wrapper for std/selectors SelectEvent so it can
    ## participate in the Sigils signaling system.
    evt*: SelectEvent

proc dataReady*(ev: SigilSocketEvent) {.signal.}
proc selectReady*(ev: SigilSelectEvent) {.signal.}
proc selectEvent*(ev: SigilSelectEvent) {.signal.}

proc newSigilSocketEvent*(
  thread: SigilSelectorThreadPtr, fd: int | Socket
): SigilSocketEvent {.gcsafe.} =
  ## Register a file/socket descriptor with the selector so that when it
  ## becomes readable, a `dataReady` signal is emitted on `ev`.
  when fd is Socket:
    let fd = fd.getFd().int
  result.new()
  result.fd = fd
  registerHandle(thread.sel, fd, {Event.Read}, SigilThreadEvent(result))

proc newSigilSelectEvent*(
  thread: SigilSelectorThreadPtr, event = newSelectEvent()
): SigilSelectEvent {.gcsafe.} =
  ## Register a custom std/selectors SelectEvent with this selector
  ## thread and emit `selectEvent` (and `selectReady` for
  ## compatibility) when it is triggered.
  result.new()
  result.evt = event
  registerEvent(thread.sel, event, SigilThreadEvent(result))

proc newSigilSelectorThread*(): ptr SigilSelectorThread =
  result = cast[ptr SigilSelectorThread](allocShared0(sizeof(
      SigilSelectorThread)))
  result[] = SigilSelectorThread() # important!
  result[].sel = newSelector[SigilThreadEvent]()
  result[].agent = ThreadAgent()
  result[].signaledLock.initLock()
  result[].timerLock.initLock()
  result[].inputs = newSigilChan()
  result[].running.store(true, Relaxed)
  result[].drain.store(true, Relaxed)

method send*(
    thread: SigilSelectorThreadPtr, msg: sink ThreadSignal,
        blocking: BlockingKinds
) {.gcsafe.} =
  var msg = isolateRuntime(msg)
  case blocking
  of Blocking:
    thread.inputs.send(msg)
  of NonBlocking:
    let sent = thread.inputs.trySend(msg)
    if not sent:
      raise newException(MessageQueueFullError, "could not send!")

method recv*(
    thread: SigilSelectorThreadPtr, msg: var ThreadSignal,
        blocking: BlockingKinds
): bool {.gcsafe.} =
  case blocking
  of Blocking:
    msg = thread.inputs.recv()
    return true
  of NonBlocking:
    result = thread.inputs.tryRecv(msg)

method setTimer*(
    thread: SigilSelectorThreadPtr, timer: SigilTimer
) {.gcsafe.} =
  ## Schedule a timer on this selector-backed thread using selector timers.
  let durMs = max(timer.duration.inMilliseconds(), 1)
  withLock thread.timerLock:
    discard thread.sel.registerTimer(durMs.int, true, timer)

proc pumpTimers(thread: SigilSelectorThreadPtr, timeoutMs: int) {.gcsafe.} =
  ## Wait up to timeoutMs and deliver any due timers via selector events.
  var keys = newSeq[ReadyKey](32)
  let n = thread.sel.selectInto(timeoutMs, keys)
  for i in 0 ..< n:
    let k = keys[i]
    # Each key corresponds to a fired selector event with associated
    # application data stored as a SigilThreadEvent (either SigilTimer or
    # SigilSocketEvent).
    let ev = getData(thread.sel, k.fd)
    if ev.isNil:
      continue

    if ev of SigilTimer:
      let tt = SigilTimer(ev)
      if thread.hasCancelTimer(tt):
        thread.removeTimer(tt)
        continue
      emit tt.timeout()

      # Reschedule if needed
      let dur = max(tt.duration.inMilliseconds(), 1).int
      if tt.isRepeat():
        discard thread.sel.registerTimer(dur, true, tt)
      else:
        if tt.count > 0:
          tt.count.dec()
        if tt.count != 0: # schedule again while count remains
          discard thread.sel.registerTimer(dur, true, tt)
    elif ev of SigilSocketEvent:
      let dr = SigilSocketEvent(ev)
      # Only emit when the descriptor is readable.
      if Event.Read in k.events:
        emit dr.dataReady()
    elif ev of SigilSelectEvent:
      let se = SigilSelectEvent(ev)
      # Forward selector events into the Sigils signal system.
      emit se.selectEvent()
      emit se.selectReady()

method poll*(
    thread: SigilSelectorThreadPtr, blocking: BlockingKinds = Blocking
): bool {.gcsafe, discardable.} =
  ## Process at most one message. For Blocking, wait briefly using
  ## selectInto then try a non-blocking recv to avoid hanging when idle.
  var sig: ThreadSignal
  case blocking
  of Blocking:
    # Check timers immediately to avoid missing short intervals.
    thread.pumpTimers(0)
    thread.pumpTimers(2) # brief wait in milliseconds
    if thread.recv(sig, NonBlocking):
      thread.exec(sig)
      result = true
  of NonBlocking:
    thread.pumpTimers(0)
    if thread.recv(sig, NonBlocking):
      thread.exec(sig)
      result = true

proc runSelectorThread*(targ: SigilSelectorThreadPtr) {.thread.} =
  {.cast(gcsafe).}:
    doAssert not hasLocalSigilThread()
    setLocalSigilThread(targ)
    targ[].threadId.store(getThreadId(), Relaxed)
    emit targ[].agent.started()
    # Run until stopped; use selector timers to provide a light sleep between polls.
    while targ.isRunning():
      targ.pumpTimers(0)
      # drain any queued signals first
      while targ.poll(NonBlocking):
        discard
      # brief wait so we're not busy-spinning
      targ.pumpTimers(5)
    # final drain if requested (mirrors async variant's behavior)
    try:
      if targ.drain.load(Relaxed):
        while targ.poll(NonBlocking):
          discard
    except CatchableError:
      discard

proc start*(thread: ptr SigilSelectorThread) =
  if thread[].exceptionHandler.isNil:
    thread[].exceptionHandler = defaultExceptionHandler
  createThread(thread[].thr, runSelectorThread, thread)

proc stop*(thread: ptr SigilSelectorThread, immediate: bool = false,
    drain: bool = false) =
  thread[].running.store(false, Relaxed)
  thread[].drain.store(drain or immediate, Relaxed)

proc join*(thread: ptr SigilSelectorThread) =
  doAssert not thread.isNil()
  thread[].thr.joinThread()

proc peek*(thread: ptr SigilSelectorThread): int =
  result = thread[].inputs.peek()
