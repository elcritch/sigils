import sigils/selectors

type LongScopedView = ref object of DynamicAgent

protocol ExtremelyLongListViewDataSourceProtocolName {.selectorScope: protocol.}:
  method objectValueForVeryLongRowName*(
    view: LongScopedView): string {.optional.}
