
import sigils/signals
import sigils/slots

export signals, slots

when not defined(gcArc) and not defined(gcOrc) and not defined(nimdoc):
  {.error: "Sigils requires --gc:arc or --gc:orc".}
