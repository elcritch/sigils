import std/[isolation, unittest]
import threading/atomics
import sigils/mailboxes

when defined(linux):
  import std/strutils

  proc rssKb(): int64 =
    for line in lines("/proc/self/status"):
      if line.startsWith("VmRSS:"):
        let fields = line.splitWhitespace()
        if fields.len >= 2:
          return parseInt(fields[1]).int64
    raise newException(IOError, "unable to read VmRSS from /proc/self/status")

elif defined(macosx):
  type
    MachPort = uint32
    MachMsgTypeNumber = uint32
    TimeValue = object
      seconds: int32
      microseconds: int32

    MachTaskBasicInfo = object
      virtualSize: uint64
      residentSize: uint64
      residentSizeMax: uint64
      userTime: TimeValue
      systemTime: TimeValue
      policy: int32
      suspendCount: int32

  const machTaskBasicInfoFlavor = 20

  var machTaskSelf {.importc: "mach_task_self_", header: "<mach/mach_init.h>".}:
    MachPort

  proc taskInfo(
      task: MachPort,
      flavor: cint,
      taskInfoOut: ptr MachTaskBasicInfo,
      taskInfoOutCount: ptr MachMsgTypeNumber,
  ): cint {.importc: "task_info", header: "<mach/task.h>".}

  proc rssKb(): int64 =
    var info: MachTaskBasicInfo
    var count = MachMsgTypeNumber(sizeof(MachTaskBasicInfo) div sizeof(cuint))
    let status = taskInfo(machTaskSelf, machTaskBasicInfoFlavor, addr info, addr count)
    doAssert status == 0, "task_info failed with kern_return_t " & $status
    int64(info.residentSize div 1024)

var destroyed: Atomic[int]

type Payload = object
  id: int

proc `=destroy`(payload: Payload) =
  if payload.id != 0:
    discard destroyed.fetchAdd(1)

suite "scheduler mailboxes":
  test "ordinary sends grow without waiting and preserve FIFO":
    let mailbox = newMailbox[int](1)
    for value in 1 .. 100:
      mailbox.send(isolate(value))
    check mailbox.peek() == 100
    for value in 1 .. 100:
      check mailbox.recv() == value
    check mailbox.peek() == 0

  test "trySend enforces the configured admission limit":
    let mailbox = newMailbox[int](1)
    check mailbox.trySend(isolate(1))
    check not mailbox.trySend(isolate(2))
    check mailbox.recv() == 1
    check mailbox.trySend(isolate(3))
    check mailbox.recv() == 3

  test "the final shared owner destroys unread payloads":
    destroyed.store(0)
    var retained: Mailbox[Payload]
    block:
      let mailbox = newMailbox[Payload](1)
      retained = mailbox
      mailbox.send(isolate(Payload(id: 1)))
      mailbox.send(isolate(Payload(id: 2)))
    check destroyed.load() == 0
    reset(retained)
    check destroyed.load() == 2

when defined(linux) or defined(macosx):
  const
    RssSampleCount = 4
    RssIterationsPerSample = 64
    RssPayloadSize = 512 * 1024
    RssMaxGrowthKb = 64 * 1024

  proc drainMailbox(
      iterations, payloadSize: int, useTryRecv: bool
  ): bool =
    let mailbox = newMailbox[string](1)
    var value: string
    for _ in 0 ..< iterations:
      mailbox.send(isolate(newString(payloadSize)))
      if useTryRecv:
        if not mailbox.tryRecv(value):
          return false
      else:
        value = mailbox.recv()
    true

  proc mailboxRssGrowth(useTryRecv: bool): int64 =
    var samples: array[RssSampleCount, int64]
    for index in 0 ..< RssSampleCount:
      doAssert drainMailbox(RssIterationsPerSample, RssPayloadSize, useTryRecv)
      samples[index] = rssKb()
    max(0'i64, samples[^1] - samples[0])

  suite "scheduler mailbox RSS":
    test "tryRecv does not retain managed payloads":
      check mailboxRssGrowth(useTryRecv = true) <= RssMaxGrowthKb

    test "recv does not retain managed payloads":
      check mailboxRssGrowth(useTryRecv = false) <= RssMaxGrowthKb
