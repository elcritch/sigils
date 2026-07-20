## Cross-platform Sigils IPC over Chronos streams and CBOR.

when not defined(feature.sigils.ipc):
  {.error: "enable the sigils 'ipc' package feature before importing sigils/ipc".}

import ipc/[chronosTransport, framing, protocol, router]

export chronosTransport, framing, protocol, router
