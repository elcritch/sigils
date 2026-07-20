import std/os

import chronos

import sigils
import sigils/ipc

type AddArgs = tuple[left: int, right: int]

let addNumbers = selector[AddArgs, int]("addNumbers")

proc addImpl(self: DynamicAgent, args: AddArgs): int =
  args.left + args.right

proc createCalculatorServer(address: TransportAddress): IpcServer =
  let
    calculator = DynamicAgent()
    calculatorApi = initProtocol(
      "Calculator",
      [requirement(addNumbers)],
    )
    router = newIpcRouter()

  discard calculator.addMethod(addNumbers, toDynamicMethod(addImpl))
  router.registerProtocol("calculator", calculator, calculatorApi)
  result = createIpcServer(address, router)
  result.start()

when defined(windows):
  const endpoint = "/sigils-calculator"
else:
  const endpoint = "/tmp/sigils-calculator.sock"

when not defined(windows):
  discard tryRemoveFile(endpoint)

proc callCalculator(server: IpcServer) {.async.} =
  let peer = await connectIpc(server.localAddress())
  try:
    echo await peer.callSelector(
      "calculator",
      addNumbers,
      (left: 20, right: 22),
    )
  finally:
    await peer.closeWait()
    await server.closeWait()

let server = createCalculatorServer(initTAddress(endpoint))
waitFor callCalculator(server)
when not defined(windows):
  discard tryRemoveFile(endpoint)
