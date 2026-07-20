import sigils/weakrefs
import sigils/agents
import sigils/actors
import sigils/signals
import sigils/slots
import sigils/selectors
import sigils/core
import sigils/threads

when defined(feature.sigils.ipc):
  import sigils/ipc

export weakrefs, agents, actors, signals, slots, selectors, threads, core

when defined(feature.sigils.ipc):
  export ipc

when not defined(gcArc) and not defined(gcOrc) and not defined(gcAtomicArc) and
    not defined(nimdoc):
  {.error: "Sigils requires --gc:arc, --gc:orc, or --gc:atomicArc".}
