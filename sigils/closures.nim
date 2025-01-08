
import signals
import slots
import agents

export signals, slots, agents

type
  ClosureAgent*[T] = ref object of Agent

method callMethod*(
    ctx: Agent, req: SigilRequest, slot: AgentProc
): SigilResponse {.base, gcsafe, effectsOf: slot.} =
  ## Route's an rpc request. 

  if slot.isNil:
    let msg = $req.procName & " is not a registered RPC method."
    let err = SigilError(code: METHOD_NOT_FOUND, msg: msg)
    result = wrapResponseError(req.origin, err)
  else:
    slot(ctx, req.params)
    let res = rpcPack(true)

    result = SigilResponse(kind: Response, id: req.origin.int, result: res)

