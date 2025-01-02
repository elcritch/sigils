import sigils/signals
import sigils/slots
import sigils/threads
import sigils/core

export signals, slots, threads, core

when not defined(gcArc) and not defined(gcOrc) and not defined(nimdoc):
  {.error: "Sigils requires --gc:arc or --gc:orc".}
