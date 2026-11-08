## Cross-platform Sigils IPC over CBOR streams.

when not defined(features.sigils.ipc):
  {.error: "enable the sigils 'ipc' package feature before importing sigils/ipc".}

import ipc/[protocol, router]
export protocol, router

when defined(features.sigils.chronos):
  import ipc/[chronosTransport, framing]
  export chronosTransport, framing
