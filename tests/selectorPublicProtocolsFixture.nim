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
  ## Exports optional close validation, close events, and observer slots.
  method windowShouldClose*(): bool {.optional.}
    ## Returns whether closing the window is allowed.

  proc windowWillClose*(window: PublicWindow) {.signal.}
    ## Reports that the window is about to close.

  proc rememberWindowClose*() {.slot.} ## Records a window-close notification.

protocol PublicWindowEvents:
  ## Exports the window-close signal across module boundaries.
  proc windowDidClose*(window: PublicWindow) {.signal.}

protocol PublicControllerEvents from PublicController:
  ## Receives window-close notifications on a controller.
  includes PublicWindowEvents

  proc windowDidClose*(self: PublicController) {.slot.} =
    self.windowClosed = true

protocol PublicCaptionedViewProtocol from PublicView:
  ## Exports receiver-bound caption access and event handling.
  method currentCaption*(self: PublicView): string =
    ## Returns the view's stored caption.
    self.caption

  proc captionWillChange*(view: PublicView) {.signal.}

  proc rememberCaption*(self: PublicView, value: string) {.slot.} =
    self.caption = value

protocol PublicCaptionVariant of PublicCaptionedViewProtocol:
  ## Supplies caption queries through a named implementation.
  method currentCaption(self: PublicView): string = ## Returns the stored caption.
    self.caption

proc rememberWindowClose*(self: PublicController) {.slot.} =
  self.windowClosed = true

proc rememberCaption*(self: PublicController, value: string) {.slot.} =
  self.lastCaption = value
