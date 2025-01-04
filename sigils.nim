import sigils/agents
import sigils/signals
import sigils/slots
import sigils/core
import sigils/threads

export agents, signals, slots, threads, core

when not defined(gcArc) and not defined(gcOrc) and not defined(nimdoc):
  {.error: "Sigils requires --gc:arc or --gc:orc".}
