import sigils/signals
import sigils/slots
import sigils/threads
import sigils/core
import sigils/request

export signals, slots, threads, core, request

when not defined(gcArc) and not defined(gcOrc) and not defined(nimdoc):
  {.error: "Sigils requires --gc:arc or --gc:orc".}
