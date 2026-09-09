import std/[os, osproc, streams, tables, strutils, unittest]
import threading/atomics
import sigils
import sigils/registry
when not defined(windows):
  import sigils/threadSelectors

type
  Source = ref object of Agent
  Counter = ref object of AgentActor
    value: int
  Receiver = ref object of Agent
    value: int
  Gate = ref object of AgentActor
  Client = ref object of AgentActor
    peer: AgentProxy[Counter]

proc ping(self: Source, value: int) {.signal.}
proc pong(self: Counter, value: int) {.signal.}
proc request(self: Client, value: int) {.signal.}

var entered: Atomic[int]
var calls: Atomic[int]
var gateEntered: Atomic[bool]
var releaseGate: Atomic[bool]
var replyFinished: Atomic[bool]
var repliesEnqueued: Atomic[int]
var clientReceived: Atomic[int]
var handledErrors: Atomic[int]
var setupActive: Atomic[bool]

proc handleExpectedError(error: ref Exception) {.gcsafe.} =
  discard handledErrors.fetchAdd(1)

proc receive(self: Receiver, value: int) {.slot.} =
  self.value = value

proc reply(self: Counter, value: int) {.slot.} =
  entered.store(value)
  emit self.pong(value)
  replyFinished.store(true)
  repliesEnqueued.store(value)

proc maybeFail(self: Counter, value: int) {.slot.} =
  if value == 1:
    raise newException(ValueError, "expected slot failure")
  discard calls.fetchAdd(1)

proc setValue(self: Counter, value: int) {.slot.} =
  self.value = value

proc noop(self: Agent, params: SigilParams) = discard

proc gated(self: Gate, value: int) {.slot.} =
  gateEntered.store(true)
  while not releaseGate.load():
    sleep(1)

proc clientReply(self: Client, value: int) {.slot.} =
  doAssert not setupActive.load(), "callback bypassed the recipient actor lease"
  clientReceived.store(value)

proc setupClient(self: Client, value: int) {.slot.} =
  setupActive.store(true)
  self.peer = lookupAgentProxy(sn"review:pool-peer", Counter)
  connectThreaded(self.peer, pong, self, Client.clientReply())
  connectThreaded(self, request, self.peer, reply)
  emit self.request(value)
  while not replyFinished.load():
    sleep(1)
  doAssert clientReceived.load() == 0
  setupActive.store(false)

proc runCase() =
  let mode = paramStr(1)
  case mode
  of "forwarding":
    let worker = newSigilThread()
    var counter = Counter()
    let proxy = counter.moveToThread(worker)
    discard worker.pollAll()
    let first = Receiver()
    let second = Receiver()
    connectThreaded(proxy, pong, first, Receiver.receive())
    connectThreaded(proxy, pong, second, Receiver.receive())
    doAssert proxy.remote[].hasSubscription(signalName(pong))
    proxy.delSubscription(signalName(pong), first, Receiver.receive())
    echo "local listener remains: ", proxy.hasSubscription(signalName(pong))
    echo "remote forwarding remains: ", proxy.remote[].hasSubscription(
        signalName(pong))
    doAssert proxy.remote[].hasSubscription(signalName(pong)), "remaining listener lost forwarding"
    emit proxy.getRemote()[].pong(19)
    doAssert first.value == 0
    doAssert second.value == 19
  of "self_delete":
    let counter = Counter()
    counter.ensureActorReady()
    counter.addSubscription(sn"self", counter, noop)
    echo "deleting self subscription"
    counter.delSubscription(sn"self", counter, noop)
    echo "self subscription deleted"
  of "registry_delete":
    let worker = newSigilThread()
    var counter = Counter()
    let proxy = counter.moveToThread(worker)
    registerGlobalName(sn"review:actor", proxy)
    discard worker.pollAll()
    doAssert removeGlobalName(sn"review:actor", proxy)
    doAssert lookupGlobalName(sn"review:actor").isNone
    echo "processing registry keepalive deletion"
    discard worker.pollAll()
    echo "registry keepalive deleted"
  of "gc_live_proxy":
    let worker = newSigilThread()
    var counter = Counter()
    let proxy = counter.moveToThread(worker)
    let source = Source()
    connectThreaded(source, ping, proxy, setValue)
    block:
      var other = Counter()
      var otherProxy = other.moveToThread(worker)
      discard worker.pollAll()
      echo "owned before other proxy destruction: ", worker.references.len
      otherProxy = nil
    discard worker.pollAll()
    echo "owned after other proxy destruction: ", worker.references.len
    echo "sending through still-live proxy"
    emit source.ping(42)
    discard worker.pollAll()
    doAssert proxy.getRemote()[].value == 42
  of "multiple_handles":
    let worker = newSigilThread()
    var counter = Counter()
    var first = counter.moveToThread(worker)
    var second: AgentProxy[Counter]
    second.initProxy(first.remote, worker.toSigilThread())
    discard worker.pollAll()
    first = nil
    discard worker.pollAll()
    let source = Source()
    connectThreaded(source, ping, second, setValue)
    emit source.ping(17)
    discard worker.pollAll()
    doAssert second.getRemote()[].value == 17
    second = nil
    discard worker.pollAll()
    doAssert worker.references.len == 0
    let pool = newSigilThreadPool(workers = 1)
    var pooled = Counter()
    var poolFirst = pooled.moveToThread(pool)
    var poolSecond: AgentProxy[Counter]
    poolSecond.initProxy(poolFirst.remote, pool.toSigilThread())
    poolFirst = nil
    doAssert pool.references.len == 1
    poolSecond = nil
    doAssert pool.references.len == 0
  of "empty_proxy":
    var proxy = AgentProxy[Counter]()
    proxy = nil
  of "pool_leak":
    let pool = newSigilThreadPool(workers = 1)
    block:
      var counter = Counter()
      var proxy = counter.moveToThread(pool)
      proxy = nil
    echo "owned after last proxy destruction: ", pool.references.len
    doAssert pool.references.len == 0, "pool retains unreferenced actor"
  of "slot_exception":
    let worker = newSigilThread()
    var counter = Counter()
    let proxy = counter.moveToThread(worker)
    let source = Source()
    connectThreaded(source, ping, proxy, maybeFail)
    discard worker.pollAll()
    for value in 1 .. 2:
      let req = initSigilRequest[Source, (int, )](
        procName = signalName(ping), args = (value, ), origin = SigilId(-1))
      proxy.remote[].inbox.send(isolateRuntime(ThreadSignal(kind: Call,
        tgt: proxy.remote.toKind(Agent), endpoint: proxy.remote[].delivery,
        req: req, slot: Counter.maybeFail())))
      worker.markReady(proxy.remote)
    try:
      discard worker.pollAll()
    except ValueError:
      echo "caught expected slot failure"
    discard worker.pollAll()
    echo "successful calls: ", calls.load(), "; pending inbox: ", proxy.remote[].inbox.peek()
    doAssert calls.load() == 1, "remaining mailbox work was stranded"
  of "queued_free":
    let source = Source()
    block:
      var receiver = Receiver()
      connectQueued(source, ping, receiver, receive)
      emit source.ping(42)
      receiver = nil
    echo "polling after receiver destruction"
    discard getCurrentSigilThread().pollAll()
  of "backpressure":
    let worker = newSigilThread()
    worker.start()
    var counter = Counter()
    let proxy = counter.moveToThread(worker, inbox = 1)
    let source = Source()
    let receiver = Receiver()
    connectThreaded(source, ping, proxy, reply)
    connectThreaded(proxy, pong, receiver, Receiver.receive())
    for value in 1 .. 2:
      emit source.ping(value)
      while entered.load() < value:
        sleep(1)
    emit source.ping(3)
    echo "sending fourth request; worker blocked on full reply inbox"
    emit source.ping(4)
    echo "fourth request sent"
    while repliesEnqueued.load() < 4:
      sleep(1)
    discard getCurrentSigilThread().pollAll()
    doAssert receiver.value == 4
    worker.setRunning(false)
    worker.join()
  of "inflight_proxy_free":
    let worker = newSigilThread()
    var counter = Counter()
    let gate = Gate()
    gate.ensureActorReady()
    var proxy = counter.moveToThread(worker)
    # The gate runs first in the worker's subscription snapshot.
    proxy.remote[].addSubscription(signalName(pong), gate, Gate.gated())
    let receiver = Receiver()
    block:
      connectThreaded(proxy, pong, receiver, Receiver.receive())
    let source = Source()
    connectThreaded(source, ping, proxy, reply)
    worker.start()
    emit source.ping(1)
    while not gateEntered.load():
      sleep(1)
    echo "destroying proxy while remote emission holds subscription snapshot; refs: ",
        proxy.unsafeGcCount()
    proxy = nil
    releaseGate.store(true)
    while not replyFinished.load():
      sleep(1)
    worker.setRunning(false)
    worker.join()
  of "pool_reply":
    let worker = newSigilThread()
    var counter = Counter()
    let proxy = counter.moveToThread(worker)
    registerGlobalName(sn"review:pool-peer", proxy)
    worker.start()
    let pool = newSigilThreadPool(workers = 2)
    var client = Client()
    let clientProxy = client.moveToThread(pool)
    let source = Source()
    connectThreaded(source, ping, clientProxy, setupClient)
    pool.start()
    emit source.ping(42)
    while not replyFinished.load():
      sleep(1)
    for attempt in 0 ..< 2_000:
      if clientReceived.load() == 42:
        break
      sleep(1)
    pool.stop()
    pool.join()
    worker.setRunning(false)
    worker.join()
    echo "client received: ", clientReceived.load(), "; proxy inbox: ",
        clientProxy.getRemote()[].peer.inbox.peek()
    doAssert clientReceived.load() == 42, "pool ignored callback proxy readiness"
  of "selector_exception":
    when not defined(windows):
      let worker = newSigilSelectorThread()
      worker.exceptionHandler = handleExpectedError
      var counter = Counter()
      let proxy = counter.moveToThread(worker)
      let source = Source()
      connectThreaded(source, ping, proxy, maybeFail)
      worker.start()
      emit source.ping(1)
      emit source.ping(2)
      for attempt in 0 ..< 2_000:
        if calls.load() == 1:
          break
        sleep(1)
      doAssert calls.load() == 1
      doAssert handledErrors.load() == 1
      worker.stop()
      worker.join()
    else:
      quit("selector timers are unavailable on Windows", 2)
  else:
    quit("unknown case", 2)

if paramCount() > 0:
  runCase()
else:
  suite "thread lifetime and delivery regressions":
    for scenario in ["forwarding", "self_delete", "registry_delete",
        "gc_live_proxy", "multiple_handles", "empty_proxy", "pool_leak",
        "slot_exception", "queued_free",
        "backpressure", "inflight_proxy_free", "pool_reply",
        "selector_exception"]:
      when defined(windows):
        if scenario == "selector_exception":
          continue
      test scenario.replace("_", " "):
        let child = startProcess(getAppFilename(), args = @[scenario],
          options = {poStdErrToStdOut})
        let status = child.waitForExit(10_000)
        if status == -1:
          child.terminate()
          discard child.waitForExit()
        let output = child.outputStream.readAll()
        child.close()
        checkpoint output
        check status == 0
