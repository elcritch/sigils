import sigils/signals
import sigils/slots
import sigils/core
import sigils/closures

type
  Counter* = ref object of Agent
    value: int
    avg: int

  Originator* = ref object of Agent

  SinkPayload = object
    value: int
    state: int

const LiveSinkPayload = 1

var
  sinkPayloadCopies: int
  sinkPayloadDestroys: int

proc `=copy`(dest: var SinkPayload, src: SinkPayload) =
  inc sinkPayloadCopies
  dest.value = src.value
  dest.state = src.state

proc `=wasMoved`(payload: var SinkPayload) =
  payload.value = 0
  payload.state = 0

proc `=destroy`(payload: var SinkPayload) =
  if payload.state == LiveSinkPayload:
    inc sinkPayloadDestroys
    payload.state = 0

proc valueChanged*(tp: Counter, val: int) {.signal.}
proc sinkPayloadChanged*(tp: Originator, payload: sink SinkPayload) {.signal.}
proc groupedSinkChanged(tp: Originator, first,
    second: sink SinkPayload) {.signal.}

proc setValue*(self: Counter, value: int) {.slot.} =
  echo "setValue! ", value
  if self.value != value:
    self.value = value
    emit self.valueChanged(value)

import unittest

suite "agent closure slots":
  test "callback manual creation":
    type ClosureRunner[T] = ref object of Agent
      rawEnv: pointer
      rawProc: pointer

    proc callClosure[T](self: ClosureRunner[T], value: int) {.slot.} =
      echo "calling closure"
      if self.rawEnv.isNil():
        let c2 = cast[T](self.rawProc)
        c2(value)
      else:
        let c3 = cast[proc(a: int, env: pointer) {.nimcall.}](self.rawProc)
        c3(value, self.rawEnv)

    var
      a {.used.} = Counter.new()
      base = 100

    let
      c1: proc(a: int) {.closure.} = proc(a: int) {.closure.} =
        base = a
      e = c1.rawEnv()
      p = c1.rawProc()
      cc = ClosureRunner[proc(a: int) {.nimcall.}](rawEnv: e, rawProc: p)
    connect(a, valueChanged, cc, ClosureRunner[proc(
        a: int) {.nimcall.}].callClosure)

    a.setValue(42)

    check a.value == 42
    check base == 42

  test "callback creation":
    var
      a = Counter()
      b = Counter(value: 100)

    let clsAgent = connectTo(a, valueChanged) do(val: int):
      echo "CLOSURE!"
      b.value = val

    check not compiles(
      block:
        connectTo(a, valueChanged) do(val: float):
          b.value = val
    )

    echo "cc3: Type: ", $typeof(clsAgent)
    emit a.valueChanged(42)
    check b.value == 42
    check clsAgent.typeof() is ClosureAgent[(int, )]

  test "sink closure consumes packed payload without copying":
    var
      source = Originator()
      receiver = Counter()

    let closureAgent = connectTo(source, sinkPayloadChanged) do(
      payload: sink SinkPayload
    ):
      receiver.value = payload.value

    discard closureAgent
    sinkPayloadCopies = 0
    sinkPayloadDestroys = 0
    block:
      var payload = SinkPayload(value: 73, state: LiveSinkPayload)
      emit source.sinkPayloadChanged(move payload)

    check receiver.value == 73
    check sinkPayloadCopies == 0
    check sinkPayloadDestroys == 1

  test "grouped sink closure parameters move independently":
    let source = Originator()
    let receiver = Counter()
    let closureAgent = connectTo(source, groupedSinkChanged) do(
        first, second: sink SinkPayload
    ):
      receiver.value = first.value + second.value
    discard closureAgent
    sinkPayloadCopies = 0
    sinkPayloadDestroys = 0
    emit source.groupedSinkChanged(
      SinkPayload(value: 17, state: LiveSinkPayload),
      SinkPayload(value: 19, state: LiveSinkPayload),
    )
    check receiver.value == 36
    check sinkPayloadCopies == 0
    check sinkPayloadDestroys == 2

  when not sigilsSlotEnvDisabled:
    test "receiver-bound sink closure consumes its owned payload":
      let source = Originator()
      let receiver = Counter()
      let offset = 5
      let conn = connectTo(source, sinkPayloadChanged, receiver) do(
          self: Counter, payload: sink SinkPayload
      ):
        self.value = payload.value + offset
      sinkPayloadCopies = 0
      sinkPayloadDestroys = 0
      emit source.sinkPayloadChanged(SinkPayload(value: 23,
          state: LiveSinkPayload))
      check receiver.value == 28
      check sinkPayloadCopies == 0
      check sinkPayloadDestroys == 1
      check conn.disconnect()
