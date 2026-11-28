## Measure the sorted subscription sequence through the public signal API.
import std/[macros, monotimes, strutils, times]
import sigils

type
  Source = ref object of Agent
  Receiver = ref object of Agent
    total: int

  SignalOperations = object
    connect, disconnect: proc(source: Source, receiver: Receiver) {.nimcall.}
    emit: proc(source: Source, value: int) {.nimcall.}

proc receive(receiver: Receiver, value: int) {.slot.} =
  receiver.total += value

macro declareSignalOperations(count: static int): untyped =
  var definitions: string
  var entries: seq[string]
  for index in 0..<count:
    let suffix = align($index, 2, '0')
    definitions.add """
proc valueChanged$1(source: Source, value: int) {.signal.}

proc connectSlot$1(source: Source, receiver: Receiver) =
  connect(source, valueChanged$1, receiver, receive)

proc disconnectSlot$1(source: Source, receiver: Receiver) =
  disconnect(source, valueChanged$1, receiver, receive)

proc emitSignal$1(source: Source, value: int) =
  emit source.valueChanged$1(value)

""" % suffix
    entries.add ("  SignalOperations(connect: connectSlot$1, " &
      "disconnect: disconnectSlot$1, emit: emitSignal$1)") % suffix
  definitions.add "let operations = [\n" & entries.join(",\n") & "\n]\n"
  result = parseStmt(definitions, currentSourcePath())

declareSignalOperations(64)

proc run(signals, fanout: int) =
  let
    subscriptions = signals * fanout
    sourceCount = min(8_192, 65_536 div subscriptions)
    emissionsPerSignal = 1_000_000 div subscriptions
  var sources = newSeq[Source](sourceCount)
  for source in sources.mitems:
    source = Source()
  var receivers = newSeq[Receiver](subscriptions)
  for receiver in receivers.mitems:
    receiver = Receiver()

  let before = getOccupiedMem()
  let connectStart = getMonoTime()
  for source in sources:
    for index in 0..<signals:
      for offset in 0..<fanout:
        operations[index].connect(source, receivers[index * fanout + offset])
  let connectNs = (getMonoTime() - connectStart).inNanoseconds
  let retainedBytes = getOccupiedMem() - before
  doAssert retainedBytes > 0, "compile with Nim's allocator"

  var sourceIndex = 0
  let emitStart = getMonoTime()
  for _ in 0..<emissionsPerSignal:
    for index in 0..<signals:
      operations[index].emit(sources[sourceIndex], 1)
      inc sourceIndex
      if sourceIndex == sourceCount:
        sourceIndex = 0
  let emitNs = (getMonoTime() - emitStart).inNanoseconds
  for receiver in receivers:
    doAssert receiver.total == emissionsPerSignal

  let disconnectStart = getMonoTime()
  for source in sources:
    for index in 0..<signals:
      for offset in 0..<fanout:
        operations[index].disconnect(source, receivers[index * fanout + offset])
  let disconnectNs = (getMonoTime() - disconnectStart).inNanoseconds
  for source in sources:
    doAssert not source.hasConnections()
  for receiver in receivers:
    doAssert not receiver.hasConnections()

  let connections = (sourceCount * subscriptions).float
  echo "signals=", signals, " fanout=", fanout,
    " connect_ns=", connectNs.float / connections,
    " emit_ns=", emitNs.float / (emissionsPerSignal * signals).float,
    " disconnect_ns=", disconnectNs.float / connections,
    " retained_bytes_per_source=", retainedBytes.float / sourceCount.float

echo "names=", (when sigilsSigilNameImmStrEnabled: "immstr"
  elif sigilsSigilNameStringEnabled: "string"
  else: "stack")
for (signals, fanout) in [(1, 1), (1, 2), (1, 3), (16, 3), (64, 4), (16, 64)]:
  run(signals, fanout)
