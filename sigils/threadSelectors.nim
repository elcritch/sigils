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
import std/nativesockets

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
    inputWake*: SelectEvent
    drain*: Atomic[bool]
    isReady*: bool
    thr*: Thread[ptr SigilSelectorThread]
    timerLock*: Lock
    timerHandles*: Table[SigilTimer, int]

  SigilSelectorThreadPtr* = ptr SigilSelectorThread

type
  SigilSocketEvent* = ref object of SigilThreadEvent
    fd*: int
    events*: set[Event]

  SigilSelectEvent* = ref object of SigilThreadEvent
    ## Wrapper for std/selectors SelectEvent so it can
    ## participate in the Sigils signaling system.
    evt*: SelectEvent

proc dataReady*(ev: SigilSocketEvent) {.signal.}
proc socketReady*(ev: SigilSocketEvent, fd: int, events: set[Event]) {.signal.}
proc writeReady*(ev: SigilSocketEvent) {.signal.}
proc selectReady*(ev: SigilSelectEvent) {.signal.}
proc selectEvent*(ev: SigilSelectEvent) {.signal.}

proc newSigilSocketEvent*(
    thread: SigilSelectorThreadPtr,
    fd: int | Socket,
    events: set[Event] = {Event.Read},
): SigilSocketEvent {.gcsafe.} =
  ## Register a descriptor and emit readiness signals for selected events.
  when fd is Socket:
    let fd = fd.getFd().int
  result.new()
  result.fd = fd
  result.events = events
  registerHandle(thread.sel, fd, events, SigilThreadEvent(result))

proc setEvents*(
    event: SigilSocketEvent,
    thread: SigilSelectorThreadPtr,
    events: set[Event],
) =
  ## Replace the readiness events watched for a registered descriptor.
  if event.isNil or thread.isNil:
    raise newException(ValueError, "selector socket event must not be nil")
  when defined(windows):
    # ``std/selectors`` stores Winsock descriptors as ``SocketHandle``;
    # ``SigilSocketEvent.fd`` remains an ``int`` for the public readiness API.
    thread.sel.updateHandle(SocketHandle(event.fd), events)
  else:
    thread.sel.updateHandle(event.fd, events)
  event.events = events

proc unregister*(event: SigilSocketEvent, thread: SigilSelectorThreadPtr) =
  ## Remove a descriptor event from its selector without closing the descriptor.
  if event.isNil or thread.isNil:
    return
  if thread.sel.contains(event.fd):
    thread.sel.unregister(event.fd)

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
  result[].inputWake = newSelectEvent()
  result[].sel.registerEvent(result[].inputWake, nil)
  result[].agent = SigilThreadAgent()
  result[].signaledLock.initLock()
  result[].timerLock.initLock()
  result[].timerHandles = initTable[SigilTimer, int]()
  result[].inputs = newSigilChan()
  result[].running.store(true, Relaxed)
  result[].drain.store(true, Relaxed)

method send*(
    thread: SigilSelectorThreadPtr, msg: sink ThreadSignal,
        blocking: BlockingKinds
) {.gcsafe.} =
  var prepared = msg
  prepared.prepareDelivery()
  var msg = isolateRuntime(move(prepared))
  case blocking
  of Blocking:
    thread.inputs.send(msg)
    debugQueuePrint "queue:thread inputs size: ",
      $thread.inputs.peek(), " thread: ", $getThreadId(thread.toSigilThread()[])
  of NonBlocking:
    let sent = thread.inputs.trySend(msg)
    if not sent:
      raise newException(MessageQueueFullError, "could not send!")
    debugQueuePrint "queue:thread inputs size: ",
      $thread.inputs.peek(), " thread: ", $getThreadId(thread.toSigilThread()[])
  thread.toSigilThread().notifyMessageEnqueued()
  thread.inputWake.trigger()

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

method setTimer*(thread: SigilSelectorThreadPtr, timer: SigilTimer) {.gcsafe.} =
  ## Schedule a timer on this selector-backed thread using selector timers.
  let durMs = timer.timerMilliseconds()
  let oneshot = (not timer.isRepeat()) and timer.count <= 1
  withLock thread.timerLock:
    thread.timerHandles[timer] = thread.sel.registerTimer(durMs, oneshot, timer)

proc unregisterTimer(thread: SigilSelectorThreadPtr, timer: SigilTimer, fd: int) =
  withLock thread.timerLock:
    if fd >= 0 and thread.sel.contains(fd):
      thread.sel.unregister(fd)
    thread.timerHandles.del(timer)

proc unregisterAllTimers(thread: SigilSelectorThreadPtr) =
  var fds: seq[int]
  withLock thread.timerLock:
    for _, fd in thread.timerHandles.pairs:
      fds.add fd
    thread.timerHandles.clear()
  for fd in fds:
    if fd >= 0 and thread.sel.contains(fd):
      thread.sel.unregister(fd)

proc closeSelectorThread*(thread: SigilSelectorThreadPtr) =
  if thread.isNil:
    return
  thread.unregisterAllTimers()
  thread.sel.close()
  thread.inputWake.close()

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
        thread.unregisterTimer(tt, k.fd)
        thread.removeTimer(tt)
        continue
      emit tt.timeout()

      if not tt.isRepeat():
        if tt.count > 0:
          tt.count.dec()
        if tt.count == 0:
          thread.unregisterTimer(tt, k.fd)
    elif ev of SigilSocketEvent:
      let dr = SigilSocketEvent(ev)
      emit dr.socketReady(dr.fd, k.events)
      if Event.Read in k.events:
        emit dr.dataReady()
      if Event.Write in k.events:
        emit dr.writeReady()
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
    thread.pumpTimers(2)
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
    try:
      emit targ[].agent.started()
    except Exception as error:
      if targ.exceptionHandler.isNil:
        raise
      targ.exceptionHandler(error)
    while targ.isRunning():
      try:
        while targ.isRunning() and targ.poll(NonBlocking):
          discard
        if targ.isRunning():
          targ.pumpTimers(-1)
      except Exception as error:
        if targ.exceptionHandler.isNil:
          raise
        targ.exceptionHandler(error)
    if targ.drain.load(Relaxed):
      var pending = true
      while pending:
        try:
          pending = targ.poll(NonBlocking)
        except Exception as error:
          if targ.exceptionHandler.isNil:
            raise
          targ.exceptionHandler(error)

proc start*(thread: ptr SigilSelectorThread) =
  if thread[].exceptionHandler.isNil:
    thread[].exceptionHandler = defaultExceptionHandler
  createThread(thread[].thr, runSelectorThread, thread)

proc stop*(
    thread: ptr SigilSelectorThread, immediate: bool = false,
        drain: bool = false
) =
  thread[].running.store(false, Relaxed)
  thread[].drain.store(drain or immediate, Relaxed)
  thread[].inputWake.trigger()

proc join*(thread: ptr SigilSelectorThread) =
  doAssert not thread.isNil()
  thread[].thr.joinThread()

proc peek*(thread: ptr SigilSelectorThread): int =
  result = thread[].inputs.peek()
