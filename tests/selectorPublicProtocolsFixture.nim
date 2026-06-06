import sigils/selectors
import sigils/slots

type
  PublicView* = ref object of DynamicAgent
    caption*: string

  PublicWindow* = ref object of DynamicAgent

  PublicController* = ref object of DynamicAgent
    lastCaption*: string
    windowClosed*: bool

protocol PublicWindowLifecycleProtocol:
  method windowShouldClose*(): bool {.optional.}
  proc windowWillClose*(window: PublicWindow) {.signal.}
  proc rememberWindowClose*() {.slot.}

protocol PublicWindowEvents:
  proc windowDidClose*(window: PublicWindow) {.signal.}

protocol PublicControllerEvents from PublicController:
  includes PublicWindowEvents

  proc windowDidClose*(self: PublicController) {.slot.} =
    self.windowClosed = true

protocol PublicCaptionedViewProtocol from PublicView:
  method currentCaption*(self: PublicView): string =
    self.caption

  proc captionWillChange*(view: PublicView) {.signal.}

  proc rememberCaption*(self: PublicView, value: string) {.slot.} =
    self.caption = value

proc rememberWindowClose*(self: PublicController) {.slot.} =
  self.windowClosed = true

proc rememberCaption*(self: PublicController, value: string) {.slot.} =
  self.lastCaption = value
