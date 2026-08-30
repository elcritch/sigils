## Optional integrations for Sigils thread schedulers.

import threadBase

export threadBase

when defined(features.sigils.siwin) or defined(feature.sigils.siwin):
  from siwin/platforms/any/window import
    EventLoopWaker, SiwinGlobals, eventLoopWaker, wake

  proc installSiwinEventLoopWaker*(
      thread: SigilThreadPtr,
      waker: EventLoopWaker,
  ) =
    ## Make successful sends to ``thread`` wake the associated Siwin event loop.
    ##
    ## Install the waker on the application-thread destination scheduler before
    ## starting producers. The existing scheduler type is preserved, including
    ## selector-, asyncdispatch-, or Chronos-backed schedulers. Only messages
    ## enqueued in the Sigils destination queue are bridged; the scheduler's own
    ## file descriptors and timer deadlines still belong to its native loop.
    if thread.isNil:
      raise newException(ValueError, "Sigils thread must not be nil")
    let retainedWaker = waker
    let wakeCallback: SigilThreadWakeCallback =
      proc() {.gcsafe, raises: [].} =
        retainedWaker.wake()
    thread.addWakeCallback(wakeCallback)

  proc installSiwinEventLoopWaker*(
      thread: SigilThreadPtr,
      globals: SiwinGlobals,
  ) =
    ## Install a retained waker copied from ``globals`` on ``thread``.
    if globals.isNil:
      raise newException(ValueError, "Siwin globals must not be nil")
    thread.installSiwinEventLoopWaker(globals.eventLoopWaker())

  proc installSiwinEventLoopWaker*(globals: SiwinGlobals): SigilThreadPtr =
    ## Install a Siwin waker on the calling thread's current Sigils scheduler.
    ##
    ## If the calling thread has no scheduler yet, Sigils first creates its
    ## configured default scheduler. The installed scheduler is returned so the
    ## application can drain it with ``pollAll`` after ``waitEvents`` returns.
    result = getCurrentSigilThread()
    result.installSiwinEventLoopWaker(globals)
