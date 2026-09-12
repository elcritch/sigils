## CBOR IPC envelopes over the transport-independent Sigils RPC router.

import ../rpcs/router as rpcRouter
import protocol

export rpcRouter

type
  IpcRouteError* = RpcRouteError
  IpcRouter* = RpcRouter

proc newIpcRouter*(): IpcRouter =
  ## Create an empty endpoint router for the CBOR IPC compatibility API.
  newRpcRouter()

proc payloadFromParams(params: SigilParams): seq[byte] =
  let data = params.ipcData()
  if data.len == 0:
    let error = newException(IpcRouteError, "RPC handler did not encode a result")
    error.code = IpcInternalError
    raise error
  stringToBytes(data)

proc handleRequest*(router: IpcRouter, envelope: IpcEnvelope): IpcEnvelope =
  ## Dispatch a CBOR IPC request and produce its response envelope.
  let resultParams = router.dispatchRequest(
    envelope.target,
    envelope.name,
    initIpcParams(bytesToString(envelope.payload)),
  )
  responseEnvelope(envelope.id, payloadFromParams(resultParams))

proc handleNotify*(router: IpcRouter, envelope: IpcEnvelope) =
  ## Dispatch a CBOR IPC notification to a registered signal.
  router.dispatchNotify(
    envelope.target,
    envelope.name,
    initIpcParams(bytesToString(envelope.payload)),
  )
