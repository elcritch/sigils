when defined(feature.sigils.siwin):
  import std/unittest

  import threading/atomics
  from siwin/platforms/any/window import
    SiwinGlobals, consumeEventLoopWake, eventLoopWaker,
    installEventLoopWakeProc
  import sigils
  import sigils/threadSelectors

  when defined(macosx):
    import std/[os, times]
    import siwin as siwinApp

  const messageCount = 3

  type ProducerRequest = object
    destination: SigilThreadPtr

  var
    wakeCount: Atomic[int]
    queueDepthAtWake: Atomic[int]
    wakeDestination: SigilThreadDefaultPtr

  proc recordWake() {.gcsafe, raises: [].} =
    discard wakeCount.fetchAdd(1)
    {.cast(gcsafe).}:
      queueDepthAtWake.store(wakeDestination.peek())

  proc enqueueFromWorker(request: ProducerRequest) {.thread.} =
    for _ in 0 ..< messageCount:
      request.destination.send(ThreadSignal(kind: Trigger))

  proc countWake() {.gcsafe, raises: [].} =
    discard wakeCount.fetchAdd(1)

  proc checkSchedulerWake(destination: SigilThreadPtr) =
    wakeCount.store(0)
    let globals = SiwinGlobals()
    globals.installEventLoopWakeProc(countWake)
    let waker = globals.eventLoopWaker()
    destination.installSiwinEventLoopWaker(waker)
    check waker.consumeEventLoopWake()
    wakeCount.store(0)

    var producer: Thread[ProducerRequest]
    createThread(
      producer,
      enqueueFromWorker,
      ProducerRequest(destination: destination),
    )
    producer.joinThread()

    check wakeCount.load() == 1
    check waker.consumeEventLoopWake()
    check destination.pollAll() == messageCount

  when defined(macosx):
    proc enqueueAfterDelay(request: ProducerRequest) {.thread.} =
      sleep(100)
      request.destination.send(ThreadSignal(kind: Trigger))

  suite "Siwin external event-loop integration":
    test "enqueue precedes a coalesced wake and the application drains the queue":
      wakeCount.store(0)
      queueDepthAtWake.store(0)

      let globals = SiwinGlobals()
      globals.installEventLoopWakeProc(recordWake)
      let waker = globals.eventLoopWaker()
      let destination = newSigilThread()
      wakeDestination = destination
      destination.toSigilThread().installSiwinEventLoopWaker(globals)
      check waker.consumeEventLoopWake()
      wakeCount.store(0)
      queueDepthAtWake.store(0)

      var producer: Thread[ProducerRequest]
      createThread(
        producer,
        enqueueFromWorker,
        ProducerRequest(destination: destination.toSigilThread()),
      )
      producer.joinThread()

      check wakeCount.load() == 1
      check queueDepthAtWake.load() >= 1
      check destination.peek() == messageCount

      check waker.consumeEventLoopWake()
      check destination.pollAll() == messageCount
      check destination.peek() == 0

    test "the same hook composes with an existing selector scheduler":
      let destination = newSigilSelectorThread()
      checkSchedulerWake(destination.toSigilThread())
      destination.closeSelectorThread()

    when defined(feature.sigils.chronos):
      test "the same hook composes with an existing Chronos scheduler":
        let destination = newSigilChronosThread()
        checkSchedulerWake(destination.toSigilThread())
        destination.close()

    when defined(macosx):
      test "a worker message interrupts the native Siwin wait":
        let globals = siwinApp.newSiwinGlobals()
        let destination = newSigilThread()
        destination.toSigilThread().installSiwinEventLoopWaker(globals)

        var producer: Thread[ProducerRequest]
        createThread(
          producer,
          enqueueAfterDelay,
          ProducerRequest(destination: destination.toSigilThread()),
        )

        while destination.peek() == 0:
          discard globals.waitEvents(initDuration(seconds = 2))
        producer.joinThread()

        check destination.pollAll() == 1
        check destination.peek() == 0
else:
  import std/unittest

  suite "Siwin external event-loop integration":
    test "requires the siwin package feature":
      skip()
