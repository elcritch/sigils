## Compatibility names for the generic CBOR-RPC router.

import ../rpcs/cborRpc

export cborRpc

type
  IpcRouteError* = RpcRouteError
  IpcRouter* = CborRpcRouter

proc newIpcRouter*(): IpcRouter =
  ## Create an empty router using the compatibility IPC name.
  newCborRpcRouter()
