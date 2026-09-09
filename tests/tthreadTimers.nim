import std/[times, unittest]
import sigils/threadAsyncs
import sigils/threadSelectors

suite "native timer intervals":
  test "sub-millisecond intervals use a positive delay":
    for duration in [initDuration(), initDuration(microseconds = 500),
        initDuration(milliseconds = -1)]:
      check newSigilTimer(duration).timerMilliseconds() == 1

  test "millisecond conversion preserves the native upper boundary":
    let duration = initDuration(milliseconds = int64(high(int)))
    check newSigilTimer(duration).timerMilliseconds() == high(int)

  when sizeof(int) == 4:
    test "oversized intervals fail before installing a native timer":
      let timer = newSigilTimer(initDuration(milliseconds = int64(high(int)) + 1))
      expect ValueError:
        discard timer.timerMilliseconds()

      # Rejection must happen before either backend touches its event-loop state.
      var asyncThread: AsyncSigilThread
      var selectorThread: SigilSelectorThread
      expect ValueError:
        (addr asyncThread).setTimer(timer)
      expect ValueError:
        (addr selectorThread).setTimer(timer)
