import std/macros

type SelectorCallCapture* = object
  ## Marks a call that packs a selector and its arguments for later dispatch.

proc captureSelectorCall*(message: NimNode): NimNode =
  if message.kind notin {nnkCall, nnkCommand}:
    error("expected a call to a declared selector", message)
  result = newCall(message[0], newCall(bindSym"SelectorCallCapture"))
  for index in 1 ..< message.len:
    result.add message[index]
