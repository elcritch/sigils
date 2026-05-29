import std/unittest

import variant

import sigils/selectors

type
  DrawingContext = ref object
    value: int

  DrawingView = ref object of DynamicAgent
    drawCount: int

protocol DrawingProtocol:
  method draw*(context: DrawingContext) {.optional.}

protocol DrawingImplementation of DrawingProtocol:
  method draw(self: DrawingView, context: DrawingContext) =
    inc self.drawCount
    context.value = 42

suite "selector variant imports":
  test "selector packing works when variant is imported by the caller":
    let
      view = DrawingView()
      context = DrawingContext()

    discard variant.newVariant(1)
    discard view.withProtocol(DrawingImplementation)

    check view.sendIfHandled(draw(), context)
    check view.drawCount == 1
    check context.value == 42
