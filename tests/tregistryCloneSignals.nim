import std/unittest
import std/os
import threading/atomics

import sigils
import sigils/threads
import sigils/registry

type
  CloneCounter = ref object of AgentActor

proc ping*(counter: AgentProxy[CloneCounter]) {.signal.}

var pingCount: Atomic[int]

proc onPing*(self: CloneCounter) {.slot.} =
  pingCount.store(pingCount.load() + 1)

suite "registry cloneSignals":
  test "lookupAgentProxy clones self-proxy connections":
    startLocalThreadDefault()

    var worker = newSigilThread()
    worker.start()

    pingCount.store(0)

    var counter = CloneCounter.new()
    let counterProxy = counter.moveToThread(worker)
    connectThreaded(counterProxy, ping, counterProxy, onPing)
    registerGlobalName(sn"cloneCounterSignalsTest", counterProxy,
        cloneSignals = true)

    let localProxy = lookupAgentProxy(sn"cloneCounterSignalsTest", CloneCounter)
    doAssert localProxy != nil
    check localProxy.hasSubscription(signalName(ping))

    emit localProxy.ping()

    for i in 1 .. 1_000:
      if pingCount.load() == 1:
        break
      os.sleep(1)

    check pingCount.load() == 1
