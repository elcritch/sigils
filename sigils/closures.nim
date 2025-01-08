
import signals
import slots
import agents
import std/macros

export signals, slots, agents

type
  ClosureAgent*[T] = ref object of Agent
    rawEnv: pointer
    rawProc: pointer

macro closureTyp(blk: typed) =
  ## figure out the signal type from the lambda and the function sig
  var
    signalTyp = nnkTupleConstr.newTree()
    blk = blk.copyNimTree()
    params = blk.params
  for i in 1 ..< params.len:
    signalTyp.add params[i][1]
  let
    fnSig = ident("fnSig")
    fnInst = ident("fnInst")
    fnTyp = getTypeImpl(blk)

  result = quote do:
    var `fnSig`: `signalTyp`
    var `fnInst`: `fnTyp` = `blk`

macro closureSlotImpl(fnSig, fnInst: typed) =
  ## figure out the slot implementation for the lambda type
  var
    blk = fnInst.getTypeImpl().copyNimTree()
    params = blk.params
  let
    fnSlot = ident("fnSlot")
    paramsIdent = ident("args")
    c1 = ident"c1"
    c2 = ident"c2"
    env = ident"rawEnv"

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

  fnSigCall2.params.add(newIdentDefs(env, ident("pointer")))
  fnCall2[0] = c2
  fnCall2.add(env)

  result = quote do:
    let `fnSlot`: AgentProc = proc(context: Agent, params: SigilParams) {.nimcall.} =
      let self = ClosureAgent[`fnSig`](context)
      if self == nil:
        raise newException(ConversionError, "bad cast")
      if context == nil:
        raise newException(ValueError, "bad value")
      var `paramsIdent`: `fnSig`
      rpcUnpack(`paramsIdent`, params)
      let rawProc: pointer = self.rawProc
      let `env`: pointer = self.rawEnv
      if `env`.isNil():
        let `c1` = cast[`fnSigCall1`](rawProc)
        `fnCall1`
      else:
        let `c2` = cast[`fnSigCall2`](rawProc)
        `fnCall2`

template connectTo*(
    a: Agent,
    signal: typed,
    blk: typed
): ClosureAgent =
  ## creates an anonymous agent and slot that calls the given closure
  ## when the `signal` event is emitted. 

  closureTyp(blk)

  var signalType {.used, inject.}: typeof(SignalTypes.`signal`(typeof(a)))
  var slotType {.used, inject.}: typeof(fnSig)

  when compiles(signalType = slotType):
    discard # don't need compile check when compiles
  else:
    signalType = slotType # let the compiler show the type mismatches

  closureSlotImpl(typeof(fnSig), fnInst)

  let
    e = fnInst.rawEnv()
    p = fnInst.rawProc()
  let agent = ClosureAgent[typeof(signalType)](rawEnv: e, rawProc: p)
  a.addSubscription(signalName(signal), agent, fnSlot)

  agent
