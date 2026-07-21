import std/os

import chronos

import sigils
import sigils/ipc

const usage = """
Usage:
  chronos_ipc server
  chronos_ipc client
"""

when defined(windows):
  const endpoint = "/sigils-calculator"
else:
  const endpoint = "/tmp/sigils-calculator.sock"

protocol Calculator:
  method addNumbers(left, right: int): int

protocol CalculatorService of Calculator:
  method addNumbers(self: DynamicAgent, left, right: int): int =
    result = left + right
    echo "addNumbers(", left, ", ", right, ") = ", result

proc createCalculatorServer(address: TransportAddress): IpcServer =
  let
    calculator = DynamicAgent().withProtocol(CalculatorService)
    router = newIpcRouter()

  router.registerProtocol("calculator", calculator, Calculator)
  result = createIpcServer(address, router)
  result.start()

proc runServer(server: IpcServer) {.async.} =
  echo "Calculator IPC server listening at ", endpoint
  echo "Press Ctrl-C to stop"
  try:
    await waitSignal(SIGINT)
  finally:
    await server.closeWait()
    when not defined(windows):
      discard tryRemoveFile(endpoint)

proc runClient() {.async.} =
  let peer = await connectIpc(initTAddress(endpoint))
  try:
    let sum = await peer.callSelector(
      "calculator",
      addNumbers,
      (left: 20, right: 22),
    )
    echo "20 + 22 = ", sum
  finally:
    await peer.closeWait()

if paramCount() != 1:
  stderr.write usage
  quit QuitFailure

case paramStr(1)
of "server":
  when not defined(windows):
    discard tryRemoveFile(endpoint)
  let server = createCalculatorServer(initTAddress(endpoint))
  waitFor runServer(server)
of "client":
  waitFor runClient()
else:
  stderr.write usage
  quit QuitFailure
