import std/[monotimes, os, osproc, strformat, unittest]

import chronos

import sigils
import sigils/ipc

const
  warmupIterations = 100
  envelopeIterations = block:
    when defined(slowbench): 1_000_000
    else: 10_000
  sequentialIterations = block:
    when defined(slowbench): 100_000
    else: 1_000
  pipelineWidth = 64
  pipelineBatches = block:
    when defined(slowbench): 2_000
    else: 100
  notificationIterations = block:
    when defined(slowbench): 500_000
    else: 5_000
  connectAttempts = 500
  connectRetryDelay = 10

type
  IpcBenchService = ref object of DynamicAgent
    notifications: int

  BenchSample = object
    operations: int
    elapsedMicros: float

  IpcBenchResult = object
    serverProcessId: int
    sequential: BenchSample
    sequentialChecksum: int
    pipelined: BenchSample
    pipelinedChecksum: int
    notifications: BenchSample
    notificationCount: int

protocol IpcBenchProtocol:
  method addNumbers(left, right: int): int
  method notificationCount(): int
  method serverPid(): int

protocol IpcBenchImplementation of IpcBenchProtocol:
  method addNumbers(self: IpcBenchService, left, right: int): int =
    left + right

  method notificationCount(self: IpcBenchService): int =
    self.notifications

  method serverPid(self: IpcBenchService): int =
    getCurrentProcessId()

proc notified(self: IpcBenchService, value: int) {.signal.}

proc recordNotification(self: IpcBenchService, value: int) {.slot.} =
  self.notifications += value

proc localIpcAddress(): tuple[address: TransportAddress, path: string] =
  when defined(windows):
    let path = "/sigils-ipc-bench-" & $getCurrentProcessId()
  else:
    let path = getTempDir() /
      ("sigils-ipc-bench-" & $getCurrentProcessId() & ".sock")
  (initTAddress(path), path)

proc createIpcBenchServer(address: TransportAddress): IpcServer =
  let
    service = IpcBenchService().withProtocol(IpcBenchImplementation)
    router = newIpcRouter()

  connect(service, notified, service, recordNotification)
  router.registerProtocol("bench", service, IpcBenchProtocol)
  router.registerSignal("events", service, toSigilName("notified"))

  result = createIpcServer(address, router)
  result.start()

proc runIpcBenchServer(path: string) =
  when not defined(windows):
    discard tryRemoveFile(path)

  let server = createIpcBenchServer(initTAddress(path))
  let shutdown = newFuture[void]("ipc.benchmark.server.shutdown")
  try:
    waitFor shutdown
  finally:
    waitFor server.closeWait()
    when not defined(windows):
      discard tryRemoveFile(path)

proc connectIpcBench(address: TransportAddress): Future[IpcPeer] {.async.} =
  var lastError = "IPC benchmark server did not become ready"
  for _ in 0 ..< connectAttempts:
    try:
      return await connectIpc(address)
    except CatchableError as error:
      lastError = error.msg
    await sleepAsync(chronos.milliseconds(connectRetryDelay))
  raise newException(IpcConnectionError, lastError)

proc sampleSince(startedAt: MonoTime, operations: int): BenchSample =
  BenchSample(
    operations: operations,
    elapsedMicros: (getMonoTime() - startedAt).inMicroseconds.float,
  )

proc report(label: string, sample: BenchSample) =
  let
    rate = sample.operations.float * 1_000_000.0 /
      max(1.0, sample.elapsedMicros)
    microsPerOperation = sample.elapsedMicros / sample.operations.float
  echo &"[bench] {label}: n={sample.operations}, " &
    &"time={sample.elapsedMicros / 1000.0:.2f} ms, " &
    &"mean={microsPerOperation:.2f} us/op, rate={rate:.0f} ops/s"

proc runIpcBenchmarks(address: TransportAddress): Future[
    IpcBenchResult] {.async.} =
  let peer = await connectIpcBench(address)
  try:
    result.serverProcessId = await peer.callSelector(
      "bench",
      serverPid,
      (),
    )

    for _ in 0 ..< warmupIterations:
      let value = await peer.callSelector(
        "bench",
        addNumbers,
        (left: 20, right: 22),
      )
      doAssert value == 42

    var startedAt = getMonoTime()
    for _ in 0 ..< sequentialIterations:
      result.sequentialChecksum += await peer.callSelector(
        "bench",
        addNumbers,
        (left: 20, right: 22),
      )
    result.sequential = sampleSince(startedAt, sequentialIterations)

    var pending = newSeqOfCap[Future[int]](pipelineWidth)
    startedAt = getMonoTime()
    for _ in 0 ..< pipelineBatches:
      pending.setLen(0)
      for _ in 0 ..< pipelineWidth:
        pending.add peer.callSelector(
          "bench",
          addNumbers,
          (left: 20, right: 22),
        )
      for call in pending:
        result.pipelinedChecksum += await call
    let pipelinedOperations = pipelineBatches * pipelineWidth
    result.pipelined = sampleSince(startedAt, pipelinedOperations)

    startedAt = getMonoTime()
    for _ in 0 ..< notificationIterations:
      await peer.notifySignal("events", "notified", (1, ))
    result.notificationCount = await peer.callSelector(
      "bench",
      notificationCount,
      (),
    )
    result.notifications = sampleSince(startedAt, notificationIterations)
  finally:
    await peer.closeWait()

if paramCount() == 2 and paramStr(1) == "--ipc-bench-server":
  runIpcBenchServer(paramStr(2))
else:
  suite "Chronos IPC benchmarks":
    test "CBOR envelope and tag-24 frame encoding":
      let envelope = requestEnvelope(
        1,
        "bench",
        "addNumbers",
        packIpcPayload((left: 20, right: 22)),
      )
      let expectedFrameSize = encodeEnvelope(envelope).len + 7
      var totalBytes = 0

      let startedAt = getMonoTime()
      for _ in 0 ..< envelopeIterations:
        totalBytes += framePayload(encodeEnvelope(envelope)).len
      let sample = sampleSince(startedAt, envelopeIterations)

      check totalBytes == envelopeIterations * expectedFrameSize
      report("IPC envelope + frame encode", sample)
      let mebibytesPerSecond = totalBytes.float * 1_000_000.0 /
        max(1.0, sample.elapsedMicros) / (1024.0 * 1024.0)
      echo &"[bench] IPC encoded bytes: frame={expectedFrameSize} bytes, " &
        &"rate={mebibytesPerSecond:.2f} MiB/s"

    test "selectors and signals cross a process boundary":
      let local = localIpcAddress()
      when not defined(windows):
        discard tryRemoveFile(local.path)

      let child = startProcess(
        getAppFilename(),
        args = ["--ipc-bench-server", local.path],
        options = {poParentStreams},
      )
      try:
        let result = waitFor runIpcBenchmarks(local.address)
        let pipelinedOperations = pipelineBatches * pipelineWidth

        check result.serverProcessId != getCurrentProcessId()
        check result.sequentialChecksum == sequentialIterations * 42
        check result.pipelinedChecksum == pipelinedOperations * 42
        check result.notificationCount == notificationIterations

        echo &"[bench] IPC process boundary: clientPid={getCurrentProcessId()}, " &
          &"serverPid={result.serverProcessId}"
        report("IPC selector sequential cross-process", result.sequential)
        report("IPC selector pipelined cross-process", result.pipelined)
        report("IPC signal cross-process", result.notifications)
      finally:
        if child.running():
          child.terminate()
        discard child.waitForExit()
        child.close()
        when not defined(windows):
          discard tryRemoveFile(local.path)
