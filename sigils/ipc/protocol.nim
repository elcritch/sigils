## Compatibility names for the generic CBOR-RPC wire protocol.

import ../rpcs/cborRpc

export cborRpc

const
  IpcProtocolVersion* = CborRpcProtocolVersion
  IpcInvalidRequest* = CborRpcInvalidRequest
  IpcMethodNotFound* = CborRpcMethodNotFound
  IpcInvalidParams* = CborRpcInvalidParams
  IpcInternalError* = CborRpcInternalError
  IpcRequest* = CborRpcRequest
  IpcResponse* = CborRpcResponse
  IpcNotify* = CborRpcNotify
  IpcError* = CborRpcError

type
  IpcProtocolError* = CborRpcProtocolError
  IpcMessageKind* = CborRpcMessageKind
  IpcEnvelope* = CborRpcEnvelope

proc packIpcPayload*[T](value: T): seq[byte] =
  ## Encode a typed value using the compatibility IPC name.
  packCborRpcPayload(value)

proc unpackIpcPayload*[T](payload: openArray[byte], _: typedesc[T]): T =
  ## Decode a typed value using the compatibility IPC name.
  unpackCborRpcPayload(payload, T)

proc encodeEnvelope*(envelope: IpcEnvelope): string =
  ## Encode an envelope using the compatibility IPC name.
  encodeCborRpcEnvelope(envelope)

proc decodeEnvelope*(data: sink string): IpcEnvelope =
  ## Decode an envelope using the compatibility IPC name.
  decodeCborRpcEnvelope(data)

proc requestEnvelope*(
    id: uint64,
    target, name: string,
    payload: sink seq[byte],
): IpcEnvelope =
  ## Construct a request using the compatibility IPC name.
  cborRpcRequestEnvelope(id, target, name, payload)

proc notifyEnvelope*(
    target, name: string,
    payload: sink seq[byte],
): IpcEnvelope =
  ## Construct a notification using the compatibility IPC name.
  cborRpcNotifyEnvelope(target, name, payload)

proc responseEnvelope*(id: uint64, payload: sink seq[byte]): IpcEnvelope =
  ## Construct a response using the compatibility IPC name.
  cborRpcResponseEnvelope(id, payload)

proc errorEnvelope*(
    id: uint64, code: int32, message: string
): IpcEnvelope =
  ## Construct an error response using the compatibility IPC name.
  cborRpcErrorEnvelope(id, code, message)
