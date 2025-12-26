import sigils/weakrefs
import sigils/agents
import sigils/actor
import sigils/signals
import sigils/slots
import sigils/core
import sigils/threads

export weakrefs, agents, actor, signals, slots, threads, core

when not defined(gcArc) and not defined(gcOrc) and not defined(gcAtomicArc) and not defined(nimdoc):
  {.error: "Sigils requires --gc:arc, --gc:orc, or --gc:atomicArc".}
