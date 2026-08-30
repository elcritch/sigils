## Cross-platform Sigils IPC over Chronos streams and CBOR.

when not defined(features.sigils.ipc) or not defined(features.sigils.chronos):
  {.error: "enable the sigils 'ipc' and 'chronos' package features before importing sigils/ipc".}

import ipc/[chronosTransport, framing, protocol, router]

export chronosTransport, framing, protocol, router
