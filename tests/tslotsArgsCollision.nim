import std/unittest

import sigils/core
import sigils/signals
import sigils/slots

type
  ActionSource = ref object of Agent

  ActionTarget = ref object of Agent
    received: int

  ActionArgs = object
    value: int

proc actionTriggered(source: ActionSource, args: ActionArgs) {.signal.}
proc actionEvent(source: ActionSource, event: ActionArgs) {.signal.}
proc actionWithContext(source: ActionSource, context: ActionArgs,
    params: ActionArgs, obj: ActionArgs) {.signal.}

proc handleAction(target: ActionTarget, event: ActionArgs) {.slot.} =
  target.received = event.value

proc handleArgs(target: ActionTarget, args: ActionArgs) {.slot.} =
  target.received = args.value

proc handleWrapperNames(target: ActionTarget, context: ActionArgs,
    params: ActionArgs, obj: ActionArgs) {.slot.} =
  target.received = context.value + params.value + obj.value

suite "slot argument name collisions":
  test "signal args payload can connect to differently named slot payload":
    let
      source = ActionSource()
      target = ActionTarget()

    connect(source, actionTriggered, target, handleAction)
    emit source.actionTriggered(ActionArgs(value: 42))

    check target.received == 42

  test "slot args payload can connect to differently named signal payload":
    let
      source = ActionSource()
      target = ActionTarget()

    connect(source, actionEvent, target, handleArgs)
    emit source.actionEvent(ActionArgs(value: 137))

    check target.received == 137

  test "signal and slot payloads can both be named args":
    let
      source = ActionSource()
      target = ActionTarget()

    connect(source, actionTriggered, target, handleArgs)
    emit source.actionTriggered(ActionArgs(value: 314))

    check target.received == 314

  test "slot payload names can match wrapper internals":
    let
      source = ActionSource()
      target = ActionTarget()

    connect(source, actionWithContext, target, handleWrapperNames)
    emit source.actionWithContext(
      ActionArgs(value: 1),
      ActionArgs(value: 2),
      ActionArgs(value: 3),
    )

    check target.received == 6
