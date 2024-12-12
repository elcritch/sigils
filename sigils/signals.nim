import std/[strutils, macros, options]
import std/times
import std/isolation
import slots
import threads

import agents

export agents
export times

proc wrapResponse*(id: AgentId, resp: RpcParams, kind = Response): AgentResponse = 
  # echo "WRAP RESP: ", id, " kind: ", kind
  result.kind = kind
  result.id = id
  result.result = resp

proc wrapResponseError*(id: AgentId, err: AgentError): AgentResponse = 
  echo "WRAP ERROR: ", id, " err: ", err.repr
  result.kind = Error
  result.id = id
  result.result = rpcPack(err)

proc wrapResponseError*(
    id: AgentId,
    code: FastErrorCodes,
    msg: string,
    err: ref Exception,
    stacktraces: bool
): AgentResponse = 
  raise err

proc parseError*(ss: Variant): AgentError = 
  ss.unpack(result)

proc parseParams*[T](ss: Variant, val: var T) = 
  ss.unpack(val)

proc callMethod*(
    slot: AgentProc,
    ctx: RpcContext,
    req: AgentRequest,
    # clientId: ClientId,
): AgentResponse {.gcsafe, effectsOf: slot.} =
  ## Route's an rpc request. 

  if slot.isNil:
    let msg = req.procName & " is not a registered RPC method."
    let err = AgentError(code: METHOD_NOT_FOUND, msg: msg)
    result = wrapResponseError(req.origin, err)
  else:
    slot(ctx, req.params)
    let res = rpcPack(true)

    result = AgentResponse(kind: Response, id: req.origin, result: res)

template packResponse*(res: AgentResponse): Variant =
  var so = newVariant()
  so.pack(res)
  so

proc getSignalName*(signal: NimNode): NimNode =
  # echo "getSignalName: ", signal.treeRepr
  if signal.kind in [nnkClosedSymChoice, nnkOpenSymChoice]:
    result = newStrLitNode signal[0].strVal
  else:
    result = newStrLitNode signal.strVal
    # echo "getSignalName:result: ", result.treeRepr

macro signalName*(signal: untyped): string =
  getSignalName(signal)

proc splitNamesImpl(slot: NimNode): Option[(NimNode, NimNode)] =
  # echo "splitNamesImpl: ", slot.treeRepr
  if slot.kind == nnkCall and slot[0].kind == nnkDotExpr:
    return splitNamesImpl(slot[0])
  elif slot.kind == nnkCall:
    result = some (
      slot[1].copyNimTree,
      slot[0].copyNimTree,
    )
  elif slot.kind == nnkDotExpr:
    result = some (
      slot[0].copyNimTree,
      slot[1].copyNimTree,
    )
  # echo "splitNamesImpl:res: ", result.repr

macro signalType*(s: untyped): auto =
  ## gets the type of the signal without 
  ## the Agent proc type
  ## 
  let p = s.getTypeInst
  # echo "\nsignalType: ", p.treeRepr
  # echo "signalType: ", p.repr
  # echo "signalType:orig: ", s.treeRepr
  if p.kind == nnkNone:
    error("cannot determine type of: " & repr(p), p)
  if p.kind == nnkSym and p.repr == "none":
    error("cannot determine type of: " & repr(p), p)
  let obj =
    if p.kind == nnkProcTy:
      p[0]
    else:
      p[0]
  # echo "signalType:p0: ", obj.repr
  result = nnkTupleConstr.newNimNode()
  for arg in obj[2..^1]:
    result.add arg[1]

proc getAgentProcTy*[T](tp: AgentProcTy[T]): T =
  discard

template checkSignalTypes*[T](
    a: Agent,
    signal: typed,
    b: Agent,
    slot: Signal[T],
    acceptVoidSlot: static bool = false,
): void =
  block:
    ## statically verify signal / slot types match
    # echo "TYP: ", repr typeof(SignalTypes.`signal`(typeof(a)))
    var signalType {.used, inject.}: typeof(SignalTypes.`signal`(typeof(a)))
    var slotType {.used, inject.}: typeof(getAgentProcTy(slot))
    when acceptVoidSlot and slotType is tuple[]:
      discard
    elif compiles(signalType = slotType):
      discard # don't need compile check when compiles
    else:
      signalType = slotType # let the compiler show the type mismatches

template connect*[T](
    a: Agent,
    signal: typed,
    b: Agent,
    slot: Signal[T],
    acceptVoidSlot: static bool = false,
): void =
  ## sets up `b` to recieve events from `a`. Both `a` and `b`
  ## must subtype `Agent`. The `signal` must be a signal proc, 
  ## while `slot` must be a slot proc.
  ## 
  runnableExamples:
      type
        Updater* = ref object of Agent

        Counter* = ref object of Agent
          value: int

      proc valueChanged*(tp: Counter, val: int) {.signal.}

      proc setValue*(self: Counter, value: int) {.slot.} =
        echo "setValue! ", value
        if self.value != value:
          self.value = value
      
      var
        a = Updater.new()
        a = Counter.new()
      connect(a, valueChanged,
              b, setValue)
      emit a.valueChanged(137) #=> prints "setValue! 137"

  checkSignalTypes(a, signal, b, slot, acceptVoidSlot)
  a.addAgentListeners(signalName(signal), b, slot)

template connect*(
    a: Agent,
    signal: typed,
    b: Agent,
    slot: untyped,
    acceptVoidSlot: static bool = false,
): void =
  let agentSlot = `slot`(typeof(b))
  checkSignalTypes(a, signal, b, agentSlot, acceptVoidSlot)
  a.addAgentListeners(signalName(signal), b, agentSlot)

proc callSlots*(obj: Agent | WeakRef[Agent], req: AgentRequest) {.gcsafe.} =
  {.cast(gcsafe).}:
    let listeners = obj.toRef().getAgentListeners(req.procName)

    # echo "call slots:req: ", req.repr
    # echo "call slots:all: ", req.procName, " ", obj.agentId, " :: ", obj.listeners

    for (tgt, slot) in listeners.items():
      echo ""
      echo "call listener:tgt: ", tgt, " ", req.procName
      # echo "call listener:slot: ", repr slot
      let tgtRef = tgt.toRef()

      var res: AgentResponse

      if tgtRef of AgentRouter:
        echo "threaded Agent!"
        let router = AgentRouter(tgtRef)
        let res = router.chan.trySend(unsafeIsolate ThreadSignal(slot: slot, req: req))
        if not res:
          raise newException(AgentSlotError, "error sending signal to thread")

      else:
        echo "regular Thread!"
        res = slot.callMethod(tgtRef, req)

      when defined(nimscript) or defined(useJsonSerde):
        discard
      else:
        discard
        variantMatch case res.result.buf as u
        of AgentError:
          raise newException(AgentSlotError, $u.code & " msg: " & u.msg)
        else:
          discard

proc emit*(call: (Agent | WeakRef[Agent], AgentRequest)) =
  let (obj, req) = call
  callSlots(obj, req)
