import signals
import slots
import agents
import std/macros

export signals, slots, agents

type ClosureAgent*[T] = ref object of Agent
  rawEnv: pointer
  rawProc: pointer

when not sigilsSlotEnvDisabled:
  type SlotConnection* = object
    source*: WeakRef[Agent]
    state*: SlotConnectionState
    signal*: SigilName
    subscription*: Subscription

  proc disconnect*(connection: SlotConnection): bool {.discardable.} =
    if connection.state.isNil or not connection.state.alive:
      return false
    if connection.source.isNil:
      connection.state.alive = false
      return false
    if not connection.source[].hasSubscription(
      connection.signal, connection.subscription
    ):
      connection.state.alive = false
      return false
    connection.source[].delSubscription(connection.signal,
        connection.subscription)
    connection.state.alive = false
    result = true

iterator closureParamTypes(params: NimNode, firstArg: int): NimNode =
  for idx in firstArg ..< params.len:
    let arg = params[idx]
    if arg.kind != nnkIdentDefs:
      error("closure slot arguments must be named parameters", arg)
    let argType = arg[^2]
    for nameIdx in 0 ..< arg.len - 2:
      yield argType

macro closureTyp(blk: typed) =
  ## figure out the signal type from the lambda and the function sig
  var
    signalTyp = nnkTupleConstr.newTree()
    blk = blk.copyNimTree()
    params = blk.params
  for paramType in params.closureParamTypes(1):
    signalTyp.add paramType
  let
    fnSig = ident("fnSig")
    fnInst = ident("fnInst")
    fnTyp = getTypeImpl(blk)

  result = quote:
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
    fnSigCall1 = quote:
      proc() {.nimcall.}
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

  result = quote:
    let `fnSlot`: AgentProc = proc(context: Agent,
        params: SigilParams) {.nimcall.} =
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

when not sigilsSlotEnvDisabled:
  macro receiverClosureTyp(target: typed, blk: typed) =
    ## Figure out the signal type and receiver type from a receiver-bound closure.
    var
      signalTyp = nnkTupleConstr.newTree()
      blk = blk.copyNimTree()
      params = blk.params

    if params.len < 2:
      error("receiver-bound closure slots must take a receiver argument", blk)
    if params[1].kind != nnkIdentDefs or params[1].len != 3:
      error("receiver-bound closure slots must take one typed receiver", params[1])
    if params[1][1].kind == nnkEmpty:
      error("receiver-bound closure slot receiver must be typed", params[1])

    for paramType in params.closureParamTypes(2):
      signalTyp.add paramType

    let
      fnSig = ident("fnSig")
      fnInst = ident("fnInst")
      fnTyp = getTypeImpl(blk)
      receiver = ident("closureReceiver")
      receiverType = params[1][1].copyNimTree()

    result = quote:
      var `fnSig`: `signalTyp`
      var `fnInst`: `fnTyp` = `blk`
      var `receiver`: `receiverType`

  macro receiverClosureSlotImpl(fnSig, fnInst: typed) =
    ## Build an env-backed slot that passes the target as the closure receiver.
    let
      blk = fnInst.getTypeImpl().copyNimTree()
      params = blk.params
      receiverType = params[1][1].copyNimTree()
      envType = genSym(nskType, "ReceiverSlotEnv")
      envSlot = ident("envSlot")
      slotEnv = ident("slotEnv")
      context = ident("context")
      packedParams = ident("params")
      env = ident("env")
      args = ident("args")
      self = ident("self")
      callback = ident("callback")

    var callbackCall = nnkCall.newTree(callback, self)
    var idx = 0
    for paramType in params.closureParamTypes(2):
      discard paramType
      callbackCall.add nnkBracketExpr.newTree(args, newLit(idx))
      idx.inc()

    result = quote:
      type `envType` = ref object of SlotEnv
        fn: typeof(`fnInst`)

      let `slotEnv`: SlotEnv = `envType`(fn: `fnInst`)

      let `envSlot`: EnvAgentProc = proc(
          `context`: Agent, `packedParams`: SigilParams, `env`: SlotEnv
      ) {.nimcall.} =
        if `context` == nil:
          raise newException(ValueError, "bad value")
        let `self` = `receiverType`(`context`)
        if `self` == nil:
          raise newException(ConversionError, "bad cast")
        var `args`: `fnSig`
        rpcUnpack(`args`, `packedParams`)
        let `callback` = `envType`(`env`).fn
        `callbackCall`

template connectTo*(a: Agent, signal: typed, blk: typed): ClosureAgent =
  ## creates an anonymous agent and slot that calls the given closure
  ## when the `signal` event is emitted.

  block:
    closureTyp(blk)

    var signalType {.used, inject.}: typeof(SignalTypes.`signal`(typeof(a)))
    var slotType {.used, inject.}: typeof(fnSig)

    when compiles(signalType = slotType):
      discard # don't need compile check when compiles
    else:
      signalType = slotType # let the compiler show the type mismatches

    closureSlotImpl(typeof(fnSig), fnInst)

    let
      e =
        when compiles(rawEnv(fnInst)):
          fnInst.rawEnv()
        else:
          pointer(nil)
      p =
        when compiles(rawProc(fnInst)):
          fnInst.rawProc()
        else:
          cast[pointer](fnInst)
    let agent = ClosureAgent[typeof(signalType)](rawEnv: e, rawProc: p)
    a.addSubscription(signalName(signal), agent, fnSlot)

    agent

when not sigilsSlotEnvDisabled:
  template connectTo*(a: Agent, sigProc: typed, b: Agent,
      blk: typed): SlotConnection =
    ## Connect a signal to a closure that receives `b` as its slot receiver.
    block:
      receiverClosureTyp(b, blk)

      var signalType {.used, inject.}: typeof(SignalTypes.`sigProc`(typeof(a)))
      var slotType {.used, inject.}: typeof(fnSig)
      var receiverType {.used, inject.}: typeof(closureReceiver)

      when compiles(signalType = slotType):
        discard
      else:
        signalType = slotType

      when compiles(receiverType = b):
        discard
      else:
        receiverType = b

      receiverClosureSlotImpl(typeof(fnSig), fnInst)

      let
        sig = signalName(sigProc)
        state = SlotConnectionState(alive: true)
        subscription = Subscription(
          tgt: b.unsafeWeakRef().asAgent(),
          envSlot: envSlot,
          env: slotEnv,
          connectionState: state,
        )

      a.addSubscription(sig, subscription)

      SlotConnection(
        source: a.unsafeWeakRef().asAgent(),
        state: state,
        signal: sig,
        subscription: subscription,
      )
