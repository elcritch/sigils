## Cross-platform Sigils IPC over Chronos streams and CBOR.

when not defined(feature.sigils.ipc) or not defined(feature.sigils.chronos):
  {.error: "enable the sigils 'ipc' and 'chronos' package features before importing sigils/ipc".}

import ipc/[chronosTransport, framing, protocol, router]

export chronosTransport, framing, protocol, router
