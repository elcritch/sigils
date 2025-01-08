
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
  # echo "CC:: blk: ", treeRepr(blk)
  echo "CC:: blk:params: ", treeRepr(blk.params)

  var
    signalTyp = nnkTupleConstr.newTree()
    blk = blk.copyNimTree()
    params = blk.params

  for i in 1 ..< params.len:
    signalTyp.add params[i][1]
  
  echo "CC:: signalTyp from blk: ", repr signalTyp
  echo "CC:: signalTyp from blk: ", repr signalTyp
  let
    fnSig = ident("fnSig")
    fnInst = ident("fnInst")
    fnTyp = getTypeImpl(blk)
    paramsIdent = ident("args")

  result = quote do:
    var `fnSig`: `signalTyp`
    var `fnInst`: `fnTyp` = `blk`

  echo "<<<CALL:\n", repr(result)
  echo ">>>\n"

macro closureSlotImpl(fnSig, fnInst: typed) =
  echo ""
  echo "CI:: fnSig:tp: ", repr getTypeImpl(fnSig)
  echo "CI:: fnSig: ", repr fnSig
  echo "CI:: fnInst:tp: ", repr(fnInst.getTypeImpl())
  echo "CI:: fnInst: ", repr(fnInst)
  echo ""

  var
    signalTyp = nnkTupleConstr.newTree()
    blk = fnInst.getTypeImpl().copyNimTree()
    params = blk.params
    sigParams = blk.params.copyNimTree()
  sigParams.del(0, 1)

  # blk.addPragma(ident "closure")
  for i in 1 ..< params.len:
    signalTyp.add params[i][1]
  
  echo "CC:: signalTyp from blk: ", repr signalTyp
  echo "CC:: signalTyp from blk: ", repr signalTyp
  let
    self = ident"self"
    fnInst = ident("fnInst")
    fnSlot = ident("fnSlot")
    paramsIdent = ident("args")
    paramSetups = mkParamsVars(paramsIdent, genSym(ident="fnApply"), sigParams)
    c1 = ident"c1"
    c2 = ident"c2"
    e = ident"e"

  var
    fnSigCall1 = quote do:
      proc () {.nimcall.}
    fnCall1 = nnkCall.newTree(c1)
  for idx, param in params[1 ..^ 1]:
    fnSigCall1.params.add(newIdentDefs(ident("a" & $idx), param[1]))
    let i = newLit(idx)
    fnCall1.add quote do:
      `paramsIdent`[`i`]
  echo "FN SIGCALL1: ", fnSigCall1.repr
  echo "FN SIGCALL1: ", fnSigCall1.treeRepr
  echo "FN CALL1: ", fnCall1.repr
  echo "FN CALL1: ", fnCall1.treeRepr

  var
    fnSigCall2 = fnSigCall1.copyNimTree()
    fnCall2 = fnCall1.copyNimTree()
  fnSigCall2.params.add(newIdentDefs(e, ident("pointer")))
  fnCall2[0] = c2
  fnCall2.add(e)

  echo "FN SIGCALL2: ", fnSigCall2.repr
  # echo "FN CALL2: ", fnSigCall2.lispRepr
  echo "FN paramSetups: ", paramSetups.treeRepr

  let mcall = nnkCall.newTree(fnInst)
  for param in params[1 ..^ 1]:
    mcall.add param[0]
  echo "FN MCALL: ", mcall.repr

  result = quote do:
    let `fnSlot`: AgentProc = proc(context: Agent, params: SigilParams) {.nimcall.} =
      let `self` = ClosureAgent[`signalTyp`](context)
      if `self` == nil:
        raise newException(ConversionError, "bad cast")
      if context == nil:
        raise newException(ValueError, "bad value")
      var `paramsIdent`: `signalTyp`
      rpcUnpack(`paramsIdent`, params)
      let rawProc: pointer = `self`.rawProc
      if `self`.rawEnv.isNil():
        let `c1` = cast[`fnSigCall1`](rawProc)
      #   `c1`()
      #   discard
      # else:
      #   let `c2` = cast[`fnSigCall2`](rawProc)
      #   # c3(value, `self`.rawEnv)
      #   # `mcall`
      #   discard
  echo "\nCALL:\n", repr(result)
  echo ""

template closureSlot*[T, V](
    fnSig: typedesc[T],
    fnInst: V,
): auto =

  static:
    echo "closureSlot: fnInst: tp: ", $typeof(fnInst)
  
  closureSlotImpl(fnSig, fnInst)

template connectTo*(
    a: Agent,
    signal: typed,
    blk: typed
): auto =

  closureTyp(blk)

  var signalType {.used, inject.}: typeof(SignalTypes.`signal`(typeof(a)))
  var slotType {.used, inject.}: typeof(fnSig)

  when compiles(signalType = slotType):
    discard # don't need compile check when compiles
  else:
    signalType = slotType # let the compiler show the type mismatches

  static:
    echo "CC:: signalType: ", $typeof(SignalTypes.`signal`(typeof(a)))
    echo "CC:: fnType: ", $typeof(fnSig)
    echo "CC:: fnInst: ", $typeof(fnInst)
    # echo "CC:: fnSlot: ", $typeof(fnSlot)

  closureSlot(typeof(fnSig), fnInst)

  ClosureAgent[typeof(signalType)]()
