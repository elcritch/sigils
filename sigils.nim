import sigils/weakrefs
import sigils/agents
import sigils/actors
import sigils/signals
import sigils/slots
import sigils/selectors
import sigils/core
import sigils/threads

when defined(features.sigils.ipc) and not defined(features.sigils.chronos):
  {.error: "the sigils 'ipc' feature requires the 'chronos' feature".}

when defined(features.sigils.ipc) and defined(features.sigils.chronos):
  import sigils/ipc

export weakrefs, agents, actors, signals, slots, selectors, threads, core

when defined(features.sigils.ipc) and defined(features.sigils.chronos):
  export ipc

when not defined(gcArc) and not defined(gcOrc) and not defined(gcAtomicArc) and
    not defined(nimdoc):
  {.error: "Sigils requires --gc:arc, --gc:orc, or --gc:atomicArc".}
