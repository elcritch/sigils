import sigils/selectors

type
  PublicWindow = ref object of DynamicAgent
  WindowSpy = ref object of DynamicAgent

protocol PublicWindowEvents:
  proc windowDidClose(window: PublicWindow) {.signal.}

protocol WindowSpyEvents of PublicWindowEvents:
  proc rememberWindowWillClose(spy: WindowSpy) {.slotFor: windowWillClose.} =
    discard
