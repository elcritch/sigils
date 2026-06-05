import std/unittest

import sigils/selectors

type
  SelectorOnlySource = ref object of DynamicAgent

protocol SelectorOnlyProtocol:
  proc selectorOnlySignal(source: SelectorOnlySource) {.signal.}
  proc selectorOnlySlot(value: int) {.slot.}

suite "protocol signal and slot declarations":
  test "protocol signals and slots compile with selectors import only":
    check SelectorOnlyProtocol.signals.len == 1
    check SelectorOnlyProtocol.slots.len == 1
    check SelectorOnlyProtocol.hasSignal(toSigilName("selectorOnlySignal"))
    check SelectorOnlyProtocol.hasSlot(toSigilName("selectorOnlySlot"))
    check SignalTypes.selectorOnlySignal(SelectorOnlySource) is tuple[]

    let source = SelectorOnlySource()
    let call = source.selectorOnlySignal()
    check call.procName == toSigilName("selectorOnlySignal")

    let weakCall = source.unsafeWeakRef().selectorOnlySignal()
    check weakCall.procName == toSigilName("selectorOnlySignal")

    static:
      doAssert not compiles(checkProtocolSlots(SelectorOnlySource,
          SelectorOnlyProtocol))
