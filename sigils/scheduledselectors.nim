## Queued and delayed command selector sends on the current Sigils scheduler.
import std/[macros, times]
import selectors
import threadBase
import threadDefault
import threadPool
import core
import private/selectorcalls

type
  SelectorTimerCallback* = proc() {.closure.}
  SelectorTimerCancellation* = proc() {.closure, gcsafe.}

  SelectorTimerScheduler* = proc(
    delay: Duration, fire: SelectorTimerCallback
  ): SelectorTimerCancellation {.closure.}
    ## Arm a one-shot timer on the current thread and return its cancellation callback.
    ## The host owns the timer until delivery or cancellation. Deliver `fire` on
    ## the scheduling thread after `delay` and after this proc returns.

  TimerRegistration = ref object of Agent
    timer: SigilTimer
    cancelHostTimer: SelectorTimerCancellation

  ScheduledState = ref object
    complete: bool
    registration: AgentEndpoint

  ScheduledSend* = ref object ## A delayed send. Keep it to cancel before it runs.
    registration: TimerRegistration
    scheduler: SigilThreadPtr
    state: ScheduledState

  ScheduledCommand[A] = object
    message: Selector[A, tuple[]]
    args: A

  ScheduledTimer[A] = ref object of SigilTimer
    target: AgentEndpoint
    command: ScheduledCommand[A]
    state: ScheduledState

proc dispatchCommand[A](context: Agent, params: SigilParams) {.nimcall.} =
  var command: ScheduledCommand[A]
  rpcUnpack(command, params)
  discard DynamicAgent(context).send(command.message, command.args)

proc deliverCommand[A](
    state: ScheduledState, target: AgentEndpoint, command: ScheduledCommand[A]
) =
  if state.complete:
    return
  state.complete = true
  defer:
    # The callback can outlive the handle. Release the registration if it survived.
    if state.registration.isAlive:
      let registration = TimerRegistration(state.registration[].target[])
      registration.timer = nil
      registration.cancelHostTimer = nil
  if target.isAlive:
    discard DynamicAgent(target[].target[]).send(command.message, command.args)

proc fireCommand[A](context: Agent, params: SigilParams) {.nimcall.} =
  let scheduled = ScheduledTimer[A](context)
  deliverCommand(scheduled.state, scheduled.target, scheduled.command)

proc enqueueSelector*[A](
    receiver: DynamicAgent, message: Selector[A, tuple[]], args: A
) =
  ## Queue a routed command on the current scheduler.
  if receiver.isNil:
    raise newException(ValueError, "receiver must not be nil")
  let scheduler = getCurrentSigilThread()
  if scheduler of SigilThreadPoolPtr:
    raise
      newException(ValueError, "scheduled selector sends do not support thread pools")
  let endpoint = receiver.endpoint()
  let command = ScheduledCommand[A](message: message, args: args)
  let request = SigilRequest(
    kind: Request, origin: SigilId(-1), procName: message.name, params: rpcPack(command)
  )
  scheduler.send(
    ThreadSignal(
      kind: Call,
      tgt: endpoint[].target,
      endpoint: endpoint,
      slot: dispatchCommand[A],
      req: request,
    )
  )

proc scheduleSelector*[A](
    receiver: DynamicAgent,
    delay: Duration,
    message: Selector[A, tuple[]],
    args: A,
    scheduleTimer: SelectorTimerScheduler = nil,
): ScheduledSend {.discardable, effectsOf: scheduleTimer.} =
  ## Schedule one routed command using the current scheduler or a host timer.
  if receiver.isNil:
    raise newException(ValueError, "receiver must not be nil")
  if delay < initDuration():
    raise newException(ValueError, "delay must not be negative")
  let scheduler = getCurrentSigilThread()
  if scheduler of SigilThreadPoolPtr or
      (scheduleTimer.isNil and scheduler of SigilThreadDefaultPtr):
    raise
      newException(ValueError, "the current scheduler does not support delayed sends")
  let
    registration = TimerRegistration()
    state = ScheduledState(registration: registration.endpoint())
    target = receiver.endpoint()
    command = ScheduledCommand[A](message: message, args: args)
  result = ScheduledSend(registration: registration, scheduler: scheduler, state: state)
  try:
    if not scheduleTimer.isNil:
      registration.cancelHostTimer = scheduleTimer(
        delay,
        proc() =
          deliverCommand(state, target, command),
      )
      return
    let timer = ScheduledTimer[A](
      duration: delay, count: 1, state: state, target: target, command: command
    )
    registration.timer = timer
    timer.addSubscription(signalName(timeout), timer, fireCommand[A])
    timer.start(result.scheduler)
  except:
    state.complete = true
    registration.timer = nil
    raise

proc cancel*(scheduled: ScheduledSend) =
  ## Cancel a pending send on the thread where it was scheduled.
  if not scheduled.isNil and not scheduled.state.complete:
    if getCurrentSigilThread() != scheduled.scheduler:
      raise newException(ValueError, "cancel the send on its scheduler's thread")
    scheduled.state.complete = true
    let registration = scheduled.registration
    let timer = move registration.timer
    if not timer.isNil:
      timer.cancel(scheduled.scheduler)
    if not registration.cancelHostTimer.isNil:
      let cancelTimer = move registration.cancelHostTimer
      cancelTimer()

proc sendLaterCaptured[A](
    receiver: DynamicAgent, command: tuple[message: Selector[A, tuple[]], args: A]
) =
  enqueueSelector(receiver, command.message, command.args)

proc sendAfterCaptured[A](
    receiver: DynamicAgent,
    delay: Duration,
    command: tuple[message: Selector[A, tuple[]], args: A],
    scheduleTimer: SelectorTimerScheduler,
): ScheduledSend {.discardable, effectsOf: scheduleTimer.} =
  scheduleSelector(receiver, delay, command.message, command.args, scheduleTimer)

macro sendLater*(receiver, message: untyped): untyped =
  ## Queue a declared selector call.
  newCall(bindSym"sendLaterCaptured", receiver, captureSelectorCall(message))

macro sendAfter*(
    receiver, delay, message: untyped, scheduleTimer: untyped = nil
): untyped =
  ## Schedule a declared selector call after a delay, optionally using a host timer.
  newCall(
    bindSym"sendAfterCaptured",
    receiver,
    delay,
    captureSelectorCall(message),
    scheduleTimer,
  )
