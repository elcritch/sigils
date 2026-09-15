import sigils/agents

when not sigilsClosuresEnabled:
  {.error: "tests/tsigilsClosures.nim requires a sigils closures define".}

import std/[monotimes, os, unittest]

import sigils/core
import sigils/closures
import sigils/threads

import tclosures

type ClosureFlagCounter = ref object of Agent
  value: int
  avg: int

type ClosureFlagSource = ref object of Agent
  destroyed: ptr bool

type ClosureActor = ref object of AgentActor
  value: int

proc `=destroy`(source: var typeof(ClosureFlagSource()[])) =
  if not source.destroyed.isNil:
    source.destroyed[] = true
  destroyAgent(source)

proc valueChanged(self: ClosureFlagCounter, value: int) {.signal.}
proc valueChanged(self: ClosureFlagSource, value: int) {.signal.}
proc valueChanged(self: ClosureActor, value: int) {.signal.}
proc trigger(self: AgentProxy[ClosureActor], value: int) {.signal.}
proc trigger(self: ClosureActor, value: int) {.slot.} =
  emit self.valueChanged(value)

suite "agent closure slots (-d:sigilsClosures)":
  test "same-thread actor endpoints preserve receiver closure environments":
    let source = ClosureFlagCounter()
    let receiver = ClosureActor()
    let offset = 7
    getCurrentSigilThread().attachActor(receiver)
    let conn = connectTo(source, valueChanged, receiver) do(
      self: ClosureActor, value: int
    ):
      self.value = value + offset
    emit source.valueChanged(5)
    check receiver.value == 12
    check conn.disconnect()

  test "moving a closure receiver fails before changing its connections":
    let thread = newSigilThread()
    thread.start()
    defer:
      thread.setRunning(false)
      thread.join()
    let source = ClosureFlagCounter()
    var receiver = ClosureActor()
    let offset = 9
    let conn = connectTo(source, valueChanged, receiver) do(
      self: ClosureActor, value: int
    ):
      self.value = value + offset
    expect ValueError:
      discard receiver.moveToThread(thread)
    require not receiver.isNil
    emit source.valueChanged(4)
    check receiver.value == 13
    check conn.disconnect()

  test "moving a closure source preserves its environment and disconnect handle":
    let thread = newSigilThread()
    thread.start()
    defer:
      thread.setRunning(false)
      thread.join()
    var source = ClosureActor()
    let receiver = ClosureFlagCounter()
    let offset = 11
    let conn = connectTo(source, valueChanged, receiver) do(
      self: ClosureFlagCounter, value: int
    ):
      self.value = value + offset
    let proxy = source.moveToThread(thread)
    connectThreaded(proxy, trigger, proxy, trigger)
    emit proxy.trigger(6)
    let deadline = getMonoTime() + initDuration(seconds = 5)
    while receiver.value != 17 and getMonoTime() < deadline:
      discard getCurrentSigilThread().pollAll()
      sleep(1)
    check receiver.value == 17
    check conn.disconnect()
    check not conn.disconnect()

  test "receiver-bound closure slot captures state and mutates target":
    var
      a = ClosureFlagCounter()
      b = ClosureFlagCounter(value: 100)
      offset = 10

    let conn = connectTo(a, valueChanged, b) do(self: ClosureFlagCounter, val: int):
      self.value = val + offset

    emit a.valueChanged(5)
    check b.value == 15

    check conn.disconnect()
    check not conn.disconnect()

    emit a.valueChanged(7)
    check b.value == 15

  test "receiver-bound closure slots keep separate environments":
    var
      a = ClosureFlagCounter()
      b = ClosureFlagCounter()
      first = 2
      second = 3

    let conn1 = connectTo(a, valueChanged, b) do(self: ClosureFlagCounter,
        val: int):
      self.value += val * first

    let conn2 = connectTo(a, valueChanged, b) do(self: ClosureFlagCounter,
        val: int):
      self.avg += val * second

    emit a.valueChanged(4)

    check b.value == 8
    check b.avg == 12

    check conn1.disconnect()
    check conn2.disconnect()

  test "disconnect after source destruction does not dereference weak source":
    var
      sourceDestroyed = false
      target = ClosureFlagCounter()
      conn: SlotConnection

    block:
      let source = ClosureFlagSource(destroyed: addr sourceDestroyed)
      conn = connectTo(source, valueChanged, target) do(
          self: ClosureFlagCounter, val: int):
        self.value = val

    GC_fullCollect()
    check sourceDestroyed
    check not conn.disconnect()
