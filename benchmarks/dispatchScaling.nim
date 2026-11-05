## Compile with --mm:arc --threads:on -d:release --opt:speed --path:.
## Vary counts to measure specialization growth; each retained adapter is called.
import std/[macros, monotimes, strutils, times]
import sigils
import sigils/[selectors, rchannels]

const
  scalingTypes {.intdefine.} = 4
  scalingMethods {.intdefine.} = 16
  scalingSignals {.intdefine.} = 0
  scalingChannels {.intdefine.} = 0
  scalingIterations {.intdefine.} = 100_000

static:
  doAssert scalingTypes > 0
  doAssert scalingMethods >= 0 and scalingSignals >= 0 and scalingChannels >= 0
  doAssert scalingIterations > 0

type
  ScalingPayload[Tag: static int] = object
    value: int
    text: string
  ScalingAgent = ref object of DynamicAgent
    total: int

macro scalingWorkload(): untyped =
  var declarations, setup, selectorLoop, signalLoop, channelLoop: string
  for index in 0 ..< scalingMethods:
    let suffix = $index
    let payload = "ScalingPayload[" & $(index mod scalingTypes) & "]"
    declarations.add "method call" & suffix & "(payload: " & payload & "): int {.selector.}\n"
    declarations.add "method impl" & suffix & "(self: ScalingAgent, payload: " &
        payload &
      "): int {.selector.} =\n  self.total = payload.value + payload.text.len + " &
          suffix &
      "\n  self.total\n"
    setup.add "doAssert agent.addMethod(call" & suffix & ", impl" & suffix & ")\n"
    selectorLoop.add "checksum += agent.call" & suffix & "(" & payload &
      "(value: iteration, text: text))\n"
  for index in 0 ..< scalingSignals:
    let suffix = $index
    let payload = "ScalingPayload[" & $(index mod scalingTypes) & "]"
    declarations.add "proc event" & suffix & "(self: ScalingAgent, payload: " &
        payload &
      ") {.signal.}\n"
    declarations.add "proc receive" & suffix &
        "(self: ScalingAgent, payload: " & payload &
      ") {.slot.} =\n  self.total = payload.value + payload.text.len + " &
          suffix & "\n"
    setup.add "connect(agent, event" & suffix & ", receiver, receive" & suffix & ")\n"
    signalLoop.add "emit agent.event" & suffix & "(" & payload &
      "(value: iteration, text: text))\nchecksum += receiver.total\n"
  for index in 0 ..< scalingChannels:
    let suffix = $index
    let payload = "ScalingPayload[" & $(index mod scalingTypes) & "]"
    setup.add "let channel" & suffix & " = newRChan[" & payload & "](1)\n"
    channelLoop.add "channel" & suffix & ".send(" & payload & "(value: iteration))\n"
    channelLoop.add "checksum += channel" & suffix & ".recv().value\n"

  result = parseStmt(declarations)
  var body = "proc runScaling() =\n  let agent = ScalingAgent()\n  let receiver = ScalingAgent()\n"
  body.add setup.indent(2).strip(leading = false) & "\n"
  body.add "  let text = repeat('x', 32)\n  var checksum = 0\n"
  for (label, work) in [("selectors", selectorLoop), ("signals", signalLoop), (
      "channels", channelLoop)]:
    if work.len > 0:
      body.add "  block:\n    let started = getMonoTime()\n    for iteration in 0 ..< scalingIterations:\n"
      body.add work.indent(6).strip(leading = false) & "\n"
      body.add "    echo \"" & label & " us=\", (getMonoTime() - started).inMicroseconds\n"
  body.add """
  let iterationSum = scalingIterations * (scalingIterations - 1) div 2
  let expected =
    (scalingMethods + scalingSignals + scalingChannels) * iterationSum +
    scalingIterations * (32 * (scalingMethods + scalingSignals) +
      scalingMethods * (scalingMethods - 1) div 2 +
      scalingSignals * (scalingSignals - 1) div 2)
  doAssert checksum == expected
  echo "checksum=", checksum
runScaling()
"""
  result.add parseStmt(body)

echo "types=", scalingTypes, " methods=", scalingMethods, " signals=",
    scalingSignals,
  " channels=", scalingChannels, " iterations=", scalingIterations
scalingWorkload()
