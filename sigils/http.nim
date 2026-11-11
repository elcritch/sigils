## Optional HTTP download backends.
## Enable and import only the backends needed by the application.

when defined(features.sigils.httpSelector):
  import http/downloads
  export downloads

when defined(features.sigils.httpAsync):
  import http/asyncDownloads
  export asyncDownloads

when defined(features.sigils.httpChronos):
  import http/chronosDownloads
  export chronosDownloads
