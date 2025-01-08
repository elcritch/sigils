
import signals
import slots
import agents
import std/macros

export signals, slots, agents

type
  ClosureAgent*[T] = ref object of Agent
    rawEnv: pointer
    rawProc: pointer

macro callWithEnv(fn, args, env: typed): NimNode =
  discard

proc callClosure[T](self: ClosureAgent[T], value: int) {.slot.} =
  echo "calling closure"
  if self.rawEnv.isNil():
    let c2 = cast[T](self.rawProc)
    c2(value)
  else:
    let c3 = cast[proc (a: int, env: pointer) {.nimcall.}](self.rawProc)
    c3(value, self.rawEnv)

# macro mkClosure(fn: typed) =
#   mkParamsType()

proc newClosureAgent*[T: proc {.closure.}](fn: T): ClosureAgent[T] =
  let
    e = fn.rawEnv()
    p = fn.rawProc()
  result = ClosureAgent[T](rawEnv: e, rawProc: p)

macro closureTyp(blk: typed) =
  echo "CC:: blk:tp: ", repr getTypeImpl(blk)
  echo "CC:: blk: ", lispRepr(blk)
  echo "CC:: blk:params: ", lispRepr(blk.params)

  var
    signalTyp = nnkTupleConstr.newTree()
    blk = blk.copyNimTree()
    params = blk.params
    sigParams = blk.params.copyNimTree()
  sigParams.del(0)

  # blk.addPragma(ident "closure")
  for i in 1 ..< params.len:
    signalTyp.add params[i][1]
  
  echo "CC:: signalTyp from blk: ", repr signalTyp
  echo "CC:: signalTyp from blk: ", repr signalTyp
  let
    objId = ident"obj"
    fnSig = ident("fnSig")
    fnInst = ident("fnInst")
    fnTyp = getTypeImpl(blk)
    fnSlot = ident("fnSlot")
    paramsIdent = ident("args")
    paramSetups = mkParamsVars(paramsIdent, genSym(ident="fnApply"), sigParams)

  let mcall = nnkCall.newTree(fnInst)
  for param in params[1 ..^ 1]:
    mcall.add param[0]

  result = quote do:
    var `fnSig`: `signalTyp`
    var `fnInst`: `fnTyp` = `blk`

    var `fnSlot`: AgentProc =
      proc(context: Agent, params: SigilParams) {.nimcall.} =
        let `objId` = ClosureAgent[`signalTyp`](context)
        if `objId` == nil:
          raise newException(ConversionError, "bad cast")
        if context == nil:
          raise newException(ValueError, "bad value")
        when `signalTyp` isnot tuple[]:
          var `paramsIdent`: `signalTyp`
          rpcUnpack(`paramsIdent`, params)
        `paramSetups`
        `mcall`
  echo "CALL:\n", repr(result)

template connectTo*(
    a: Agent,
    signal: typed,
    blk: typed
): auto =

  closureTyp(blk)

  var signalType {.used, inject.}: typeof(SignalTypes.`signal`(typeof(a)))
  var slotType {.used, inject.}: typeof(fnSig)
  # var slot: AgentProc

  when compiles(signalType = slotType):
    discard # don't need compile check when compiles
  else:
    signalType = slotType # let the compiler show the type mismatches

  static:
    echo "CC:: signalType: ", $typeof(SignalTypes.`signal`(typeof(a)))
    echo "CC:: fnType: ", $typeof(fnSig)
    echo "CC:: fnInst: ", $typeof(fnInst)
    echo "CC:: fnSlot: ", $typeof(fnSlot)

  ClosureAgent[typeof(signalType)]()
