
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
  var
    blk = fnInst.getTypeImpl().copyNimTree()
    params = blk.params
  let
    self = ident"self"
    fnInst = ident("fnInst")
    fnSlot = ident("fnSlot")
    paramsIdent = ident("args")
    c1 = ident"c1"
    c2 = ident"c2"
    e = ident"rawEnv"

  # setup call without env pointer
  var
    fnSigCall1 = quote do:
      proc () {.nimcall.}
    fnCall1 = nnkCall.newTree(c1)
  for idx, param in params[1 ..^ 1]:
    fnSigCall1.params.add(newIdentDefs(ident("a" & $idx), param[1]))
    let i = newLit(idx)
    fnCall1.add quote do:
      `paramsIdent`[`i`]

  # setup call with env pointer
  var
    fnSigCall2 = fnSigCall1.copyNimTree()
    fnCall2 = fnCall1.copyNimTree()

  fnSigCall2.params.add(newIdentDefs(e, ident("pointer")))
  fnCall2[0] = c2
  fnCall2.add(e)

  var construct = nnkTupleConstr.newTree()
  for param in params[1 ..^ 1]:
    construct.add param[0]

  result = quote do:
    let `fnSlot`: AgentProc = proc(context: Agent, params: SigilParams) {.nimcall.} =
      let `self` = ClosureAgent[`fnSig`](context)
      if `self` == nil:
        raise newException(ConversionError, "bad cast")
      if context == nil:
        raise newException(ValueError, "bad value")
      var `paramsIdent`: `fnSig`
      rpcUnpack(`paramsIdent`, params)
      let rawProc: pointer = `self`.rawProc
      let `e`: pointer = `self`.rawEnv
      if `self`.rawEnv.isNil():
        let `c1` = cast[`fnSigCall1`](rawProc)
        `fnCall1`
      else:
        let `c2` = cast[`fnSigCall2`](rawProc)
        `fnCall2`

    proc rpcMethod(
        self: ClosureAgent[typeof(signalType)]
    ): (Agent, SigilRequestTy[ClosureAgent[typeof(signalType)]]) =
      # let args = `construct`
      let name: SigilName = toSigilName(`signalName`)
      # let req = initSigilRequest[`firstType`, typeof(args)](
        # procName = name, args = args, origin = `objId`.getId()
      # )
      # result = (`objId`, req)

    
  echo "<<<CALL:\n", repr(result)
  echo ">>>"

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
