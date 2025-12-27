import std/terminal
import std/locks

when defined(sigilsDebugPrint) or defined(sigilsDebugQueue):
  var
    pcolors* = [fgRed, fgYellow, fgMagenta, fgCyan]
    pcnt*: int = 0
    pidx* {.threadVar.}: int
    plock: Lock
    debugPrintQuiet* = false

  plock.initLock()

proc debugPrintImpl*(msgs: varargs[string, `$`]) {.raises: [].} =
  when defined(sigilsDebugPrint):
    {.cast(gcsafe).}:
      try:
        # withLock plock:
        block:
          let
            tid = getThreadId()
            color =
              if pidx == 0:
                fgBlue
              else:
                pcolors[pidx mod pcolors.len()]
          var msg = ""
          for m in msgs:
            msg &= m
          stdout.styledWriteLine color, msg, {styleBright}, &" [th: {$tid}]"
          stdout.flushFile()
      except IOError:
        discard

template debugPrint*(msgs: varargs[untyped]) =
  when defined(sigilsDebugPrint):
    if not debugPrintQuiet:
      debugPrintImpl(msgs)

template debugQueuePrint*(msgs: varargs[untyped]) =
  when defined(sigilsDebugQueue):
    if not debugPrintQuiet:
      debugPrintImpl(msgs)

proc brightPrint*(color: ForegroundColor, msg, value: string, msg2 = "", value2 = "") =
  when defined(sigilsDebugPrint):
    if not debugPrintQuiet:
      stdout.styledWriteLine color,
        msg,
        {styleBright, styleItalic},
        value,
        resetStyle,
        color,
        msg2,
        {styleBright, styleItalic},
        value2

proc brightPrint*(msg, value: string, msg2 = "", value2 = "") =
  brightPrint(fgGreen, msg, value, msg2, value2)
