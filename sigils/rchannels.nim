#
#
#                                    Nim's Runtime Library
#        (c) Copyright 2021 Andreas Prell, Mamy André-Ratsimbazafy & Nim Contributors
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#
## This module works only with one of `--mm:arc` / `--mm:atomicArc` / `--mm:orc`
## compilation flags.
##
## .. warning:: This module is experimental and its interface may change.
##
## Historical lineage: this module was adapted from Nim's shared-memory channel
## implementation, which credited Mamy André-Ratsimbazafy's
## [legacy Weave channels](https://github.com/mratsim/weave/blob/5696d94e6358711e840f8c0b7c684fcc5cbd4472/unused/channels/channels_legacy.nim)
## and Andreas Prell's
## [C shared-memory channels](https://github.com/aprell/tasking-2.0/blob/master/src/channel_shm/channel.c).
##
## This implementation has since been rewritten for Sigils around a fixed
## `seq[Isolated[T]]` ring and `system.swap`. It retains the mutex and
## condition-variable channel model from that lineage, but its payload lifetime,
## overwrite, and teardown handling have substantially diverged from the
## original byte-buffer implementation.
##
## This module implements multi-producer multi-consumer channels - a concurrency
## primitive with a high-level interface intended for communication and
## synchronization between threads. It allows sending and receiving typed, isolated
## data, enabling safe and efficient concurrency.
##
## The `RChan` type represents a generic fixed-size channel object that internally manages
## the underlying resources and synchronization. It has to be initialized using
## the `newRChan` proc. Sending and receiving operations are provided by the
## blocking `send` and `recv` procs, and non-blocking `trySend` and `tryRecv`
## procs. For ring buffer behavior, use the `push` proc rather than `send`.
## Send operations add messages to the channel, receiving operations remove them,
## while `push` adds a message or overwrites the oldest message if the channel is full.
##
## Payload construction, extraction, assignment, and destruction run outside
## the channel lock. Payload destructors must not raise. If assigning a received
## payload raises, the message has already been removed; the channel remains
## usable, but the payload's hooks determine the destination's state.
## Custom sink hooks must leave destinations safe to destroy and must transfer
## or release incoming resources even when raising.
##
## During final-owner teardown, reentrant `peek` returns zero and `trySend`,
## `tryTake`, and `tryRecv` return false. `send`, `push`, `recv`, and `recvIso`
## raise `ValueError` instead of waiting or accepting another message.
##
## See also:
## * [std/isolation](https://nim-lang.org/docs/isolation.html)
##
## The following is a simple example of two different ways to use channels:
## blocking and non-blocking.

runnableExamples("--threads:on --gc:orc"):
  import std/os

  # In this example a channel is declared at module scope.
  # Channels are generic, and they include support for passing objects between
  # threads.
  # Note that isolated data passed through channels is moved around.
  var RChan = newRChan[string]()

  block example_blocking:
    # This proc will be run in another thread.
    proc basicWorker() =
      RChan.send("Hello World!")

    # Launch the worker.
    var worker: Thread[void]
    createThread(worker, basicWorker)

    # Block until the message arrives, then print it out.
    var dest = ""
    dest = RChan.recv()
    assert dest == "Hello World!"

    # Wait for the thread to exit before moving on to the next example.
    worker.joinThread()

  block example_non_blocking:
    # This is another proc to run in a background thread. This proc takes a while
    # to send the message since it first sleeps for some time.
    proc slowWorker(delay: Natural) =
      # `delay` is a period in milliseconds
      sleep(delay)
      RChan.send("Another message")

    # Launch the worker with a delay set to 2 seconds (2000 ms).
    var worker: Thread[Natural]
    createThread(worker, slowWorker, 2000)

    # This time, use a non-blocking approach with tryRecv.
    # Since the main thread is not blocked, it could be used to perform other
    # useful work while it waits for data to arrive on the channel.
    var messages: seq[string]
    while true:
      var msg = ""
      if RChan.tryRecv(msg):
        messages.add msg # "Another message"
        break
      messages.add "Pretend I'm doing useful work..."
      # For this example, sleep in order not to flood the sequence with too many
      # "pretend" messages.
      sleep(400)

    # Wait for the second thread to exit before cleaning up the channel.
    worker.joinThread()

    # Thread exits right after receiving the message
    assert messages[^1] == "Another message"
    # At least one non-successful attempt to receive the message had to occur.
    assert messages.len >= 2

  block example_non_blocking_overwrite:
    var chanRingBuffer = newRChan[string](elements = 1)
    chanRingBuffer.push("Hello")
    chanRingBuffer.push("World")
    var msg = ""
    assert chanRingBuffer.tryRecv(msg)
    assert msg == "World"

when not (defined(gcArc) or defined(gcOrc) or defined(gcAtomicArc) or defined(nimdoc)):
  {.
    error:
      "This module requires one of --mm:arc / --mm:atomicArc / --mm:orc compilation flags"
  .}

import std/[atomics, isolation, locks]

# Channel
# ------------------------------------------------------------------------------

type
  RChanData[T] = object
    lock: Lock
    spaceAvailableCV, dataAvailableCV: Cond
    slots: seq[Isolated[T]]
    head, count: int
    atomicCounter: Atomic[int]

  RChan*[T] = object ## Typed channel
    d: ptr RChanData[T]

# Slots are allocated once. Unoccupied slots always contain empty values.
# Only system.swap transfers payload ownership under the lock: unlike an
# assignment or move, it cannot invoke T's lifetime hooks. Payload-owning locals
# must outlive the locked scope so even their implicit destructors run unlocked.

proc allocChannel[T](n: Positive): ptr RChanData[T] =
  # newSeq applies T's field defaults. Vacant slots must instead contain the
  # zero representation, or sending could swap a default payload back to src.
  var slots = newSeqOfCap[Isolated[T]](n)
  for _ in 0 ..< n:
    slots.add(zeroDefault(Isolated[T]))
  result = cast[ptr RChanData[T]](allocShared0(sizeof(RChanData[T])))
  system.swap(result[].slots, slots)
  result[].atomicCounter.store(1, moRelaxed)
  initLock(result[].lock)
  initCond(result[].spaceAvailableCV)
  initCond(result[].dataAvailableCV)

proc freeChannel[T](channel: ptr RChanData[T]) =
  if channel.isNil:
    return

  # The final owner has exclusive access. Detach before invoking destructors:
  # an empty slots buffer marks teardown and rejects reentrant sends/receives.
  # Destroy the detached storage before dismantling the synchronization objects
  # so payload destructors may still call peek/tryRecv/tryTake.
  block:
    var slots: seq[Isolated[T]]
    system.swap(slots, channel[].slots)
    channel[].head = 0
    channel[].count = 0
  deinitCond(channel[].spaceAvailableCV)
  deinitCond(channel[].dataAvailableCV)
  deinitLock(channel[].lock)
  deallocShared(channel)

func nextIndex(index, capacity: int): int {.inline.} =
  if index == capacity - 1:
    0
  else:
    index + 1

proc channelSend[T](
    channel: ptr RChanData[T],
    value: var Isolated[T],
    blocking: static bool,
    overwrite: static bool,
): bool =
  assert not channel.isNil
  when overwrite:
    var dropped: Isolated[T]
  acquire(channel[].lock)
  try:
    let capacity = channel[].slots.len
    if capacity == 0:
      return false
    when overwrite:
      if channel[].count == capacity:
        system.swap(dropped, channel[].slots[channel[].head])
        channel[].head = nextIndex(channel[].head, capacity)
        dec channel[].count
    elif blocking:
      while channel[].count == capacity:
        wait(channel[].spaceAvailableCV, channel[].lock)
    else:
      if channel[].count == capacity:
        return false

    # Compute (head + count) mod capacity without overflowing the sum.
    let remaining = capacity - channel[].head
    let tail =
      if channel[].count >= remaining:
        channel[].count - remaining
      else:
        channel[].head + channel[].count
    system.swap(value, channel[].slots[tail])
    inc channel[].count
    signal(channel[].dataAvailableCV)
    result = true
  finally:
    release(channel[].lock)

proc channelReceive[T](
    channel: ptr RChanData[T], value: var Isolated[T], blocking: static bool
): bool =
  # Internal callers supply an empty value to leave the vacated slot empty.
  assert not channel.isNil
  acquire(channel[].lock)
  try:
    if channel[].slots.len == 0:
      return false
    when blocking:
      while channel[].count == 0:
        wait(channel[].dataAvailableCV, channel[].lock)
    else:
      if channel[].count == 0:
        return false

    system.swap(value, channel[].slots[channel[].head])
    channel[].head = nextIndex(channel[].head, channel[].slots.len)
    dec channel[].count
    signal(channel[].spaceAvailableCV)
    result = true
  finally:
    release(channel[].lock)

proc raiseClosedChannel() {.noinline, noreturn.} =
  raise newException(ValueError, "RChan is being destroyed")

# Public API
# ------------------------------------------------------------------------------

template frees(c) =
  if c.d != nil:
    # fetchSub returns the count before decrementing, so one means this is the
    # final owner.
    if c.d.atomicCounter.fetchSub(1, moAcquireRelease) == 1:
      freeChannel(c.d)

when defined(nimAllowNonVarDestructor):
  proc `=destroy`*[T](c: RChan[T]) =
    frees(c)

else:
  proc `=destroy`*[T](c: var RChan[T]) =
    frees(c)

proc `=wasMoved`*[T](x: var RChan[T]) =
  x.d = nil

proc `=dup`*[T](src: RChan[T]): RChan[T] =
  if src.d != nil:
    discard fetchAdd(src.d.atomicCounter, 1, moRelaxed)
  result.d = src.d

proc `=copy`*[T](dest: var RChan[T], src: RChan[T]) =
  ## Shares `Channel` by reference counting.
  if src.d != nil:
    discard fetchAdd(src.d.atomicCounter, 1, moRelaxed)
  `=destroy`(dest)
  dest.d = src.d

proc trySend*[T](c: RChan[T], src: sink Isolated[T]): bool {.inline.} =
  ## Tries to send the message `src` to the channel `c`.
  ##
  ## Takes ownership of `src`, including on failure. Use `tryTake` to preserve
  ## an isolated source when the channel is full.
  ## Doesn't block waiting for space in the channel to become available.
  ## Instead returns after an attempt to send a message was made.
  ##
  ## .. warning:: In high-concurrency situations, consider using an exponential
  ##    backoff strategy to reduce contention and improve the success rate of
  ##    operations.
  ##
  ## Returns `false` if the channel is full or is being destroyed.
  result = channelSend(c.d, src, false, false)

template trySend*[T](c: RChan[T], src: T): bool =
  ## Helper template for `trySend <#trySend,RChan[T],sinkIsolated[T]>`_.
  ##
  ## .. warning:: For repeated sends of the same value, consider using the
  ##    `tryTake <#tryTake,RChan[T],Isolated[T]>`_ proc with a pre-isolated
  ##    value to avoid unnecessary copying.
  mixin isolate
  trySend(c, isolate(src))

proc tryTake*[T](c: RChan[T], src: var Isolated[T]): bool {.inline.} =
  ## Tries to send the message `src` to the channel `c`.
  ##
  ## On success, transfers ownership and leaves `src` empty. On failure,
  ## leaves `src` unchanged. This proc is suitable when `src` cannot be copied.
  ##
  ## Doesn't block waiting for space in the channel to become available.
  ## Instead returns after an attempt to send a message was made.
  ##
  ## .. warning:: In high-concurrency situations, consider using an exponential
  ##    backoff strategy to reduce contention and improve the success rate of
  ##    operations.
  ##
  ## Returns `false` if the channel is full or is being destroyed.
  result = channelSend(c.d, src, false, false)

proc tryRecv*[T](c: RChan[T], dst: var T): bool {.inline.} =
  ## Tries to receive a message from the channel `c` and fill `dst` with its value.
  ##
  ## Doesn't block waiting for messages in the channel to become available.
  ## Instead returns after an attempt to receive a message was made.
  ##
  ## .. warning:: In high-concurrency situations, consider using an exponential
  ##    backoff strategy to reduce contention and improve the success rate of
  ##    operations.
  ##
  ## Returns `false` and does not change `dst` if no message was received.
  var received: Isolated[T]
  if channelReceive(c.d, received, false):
    dst = extract(received)
    result = true

proc send*[T](c: RChan[T], src: sink Isolated[T]) {.inline.} =
  ## Sends the message `src` to the channel `c`.
  ## This blocks the sending thread until `src` was successfully sent.
  ##
  ## The memory of `src` is moved, not copied.
  ##
  ## If the channel is already full with messages this will block the thread until
  ## messages from the channel are removed.
  when defined(gcOrc) and defined(nimSafeOrcSend):
    GC_runOrc()
  if not channelSend(c.d, src, true, false):
    raiseClosedChannel()

template send*[T](c: RChan[T], src: T) =
  ## Helper template for `send`.
  mixin isolate
  send(c, isolate(src))

proc push*[T](c: RChan[T], src: sink Isolated[T]) {.inline.} =
  ## Pushes the message `src` to the channel `c`.
  ## This is a non-blocking operation that overwrites the oldest message if the channel is full.
  ##
  ## The memory of `src` is moved, not copied.
  when defined(gcOrc) and defined(nimSafeOrcSend):
    GC_runOrc()
  if not channelSend(c.d, src, false, true):
    raiseClosedChannel()

template push*[T](c: RChan[T], src: T) =
  ## Helper template for `push`.
  mixin isolate
  push(c, isolate(src))

proc recv*[T](c: RChan[T], dst: var T) {.inline.} =
  ## Receives a message from the channel `c` and fill `dst` with its value.
  ##
  ## This blocks the receiving thread until a message was successfully received.
  ##
  ## If the channel does not contain any messages this will block the thread until
  ## a message get sent to the channel.
  var received: Isolated[T]
  if not channelReceive(c.d, received, true):
    raiseClosedChannel()
  dst = extract(received)

proc recv*[T](c: RChan[T]): T {.inline.} =
  ## Receives a message from the channel.
  ## A version of `recv`_ that returns the message.
  recv(c, result)

proc recvIso*[T](c: RChan[T]): Isolated[T] {.inline.} =
  ## Receives a message from the channel.
  ## Returns the isolated message directly, without extracting its payload.
  if not channelReceive(c.d, result, true):
    raiseClosedChannel()

proc peek*[T](c: RChan[T]): int {.inline.} =
  ## Returns an estimation of the current number of messages held by the channel.
  acquire(c.d[].lock)
  try:
    result = c.d[].count
  finally:
    release(c.d[].lock)

proc newRChan*[T](elements: Positive = 30): RChan[T] =
  ## An initialization procedure, necessary for acquiring resources and
  ## initializing internal state of the channel.
  ##
  ## `elements` is the capacity of the channel and thus how many messages it can hold
  ## before it refuses to accept any further messages.
  result = RChan[T](d: allocChannel[T](elements))
