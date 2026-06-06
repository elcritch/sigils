import tables, strutils, typetraits, macros

import agents

export agents

const SigilDebugSlots {.strdefine: "sigils.DebugSlots".}: string = ""

proc firstArgument(params: NimNode): (NimNode, NimNode) =
  if params.len() == 1:
    error("Slots must take an Agent as the first argument.", params)
  if params != nil and params.len > 0 and params[1] != nil and
      params[1].kind == nnkIdentDefs:
    result = (ident params[1][0].strVal, params[1][1])
  else:
    result = (ident "", newNimNode(nnkEmpty))

iterator paramsIter(params: NimNode): tuple[name, ntype: NimNode] =
  for i in 1 ..< params.len:
    let arg = params[i]
    let argType = arg[^2]
    for j in 0 ..< arg.len - 2:
      yield (arg[j], argType)

proc mkParamsVars*(paramsIdent, paramsType, params: NimNode): NimNode =
  ## Create local variables for each parameter in the actual RPC call proc
  if params.isNil:
    return

  result = newStmtList()
  var varList = newSeq[NimNode]()
  var cnt = 0
  for paramid, paramType in paramsIter(params):
    let idx = newIntLitNode(cnt)
    let vars = quote:
      var `paramid`: `paramType` = `paramsIdent`[`idx`]
    varList.add vars
    cnt.inc()
  result.add varList
  # echo "paramsSetup return:\n", treeRepr result

proc mkParamsType*(paramsIdent, paramsType, params,
    genericParams: NimNode): NimNode =
  ## Create a type that represents the arguments for this rpc call
  ##
  ## Example:
  ##
  ##   proc multiplyrpc(a, b: int): int {.rpc.} =
  ##     result = a * b
  ##
  ## Becomes:
  ##   proc multiplyrpc(params: RpcType_multiplyrpc): int =
  ##     var a = params.a
  ##     var b = params.b
  ##
  ##   proc multiplyrpc(params: RpcType_multiplyrpc): int =
  ##
  if params.isNil:
    return

  var tup = quote:
    type `paramsType` = tuple[]
  for paramIdent, paramType in paramsIter(params):
    # processing multiple variables of one type
    tup[0][2].add newIdentDefs(paramIdent, paramType)
  result = tup
  result[0][1] = genericParams.copyNimTree()
  # echo "mkParamsType: ", genericParams.treeRepr

proc updateProcsSig(
    node: NimNode, isPublic: bool, gens: NimNode, procLineInfo: LineInfo
) =
  if node.kind in [nnkProcDef, nnkTemplateDef]:
    node[0].setLineInfo(procLineInfo)
    let name = node[0]
    if isPublic:
      node[0] = nnkPostfix.newTree(newIdentNode("*"), name)
    node[2] = gens.copyNimTree()
    node[^1].setLineInfo(procLineInfo)
  else:
    for ch in node:
      ch.updateProcsSig(isPublic, gens, procLineInfo)


macro rpcImpl*(p: untyped, publish: untyped, qarg: untyped): untyped =
  ## Define a remote procedure call.
  ## Input and return parameters are defined using proc's with the `rpc`
  ## pragma.
  ##
  ## For example:
  ## .. code-block:: nim
  ##    proc methodname(param1: int, param2: float): string {.rpc.} =
  ##      result = $param1 & " " & $param2
  ##    ```
  ##
  ## Input parameters are automatically marshalled from fast rpc binary
  ## format (msgpack) and output parameters are automatically marshalled
  ## back to the fast rpc binary format (msgpack) for transport.

  let
    path = $p[0]
    procLineInfo = p.lineInfoObj
    genericParams = p[2]
    params = p[3]
    # pragmas = p[4]
    body = p[6]

  result = newStmtList()
  var
    (_, firstType) = params.firstArgument()
    parameters = params.copyNimTree()

  let
    # determine if this is a "signal" rpc method
    isSignal = publish.kind == nnkStrLit and publish.strVal == "signal"

  parameters.del(0, 1)
  # echo "parameters: ", parameters.treeRepr

  let
    # rpc method names
    pathStr = $path
    signalName = pathStr.strip(false, true, {'*'})
    procNameStr = p.name().repr
    isPublic = pathStr.endsWith("*")
    isGeneric = genericParams.kind != nnkEmpty

    rpcMethodGen = genSym(nskProc, procNameStr)
    procName = ident(procNameStr) # ident("agentSlot_" & rpcMethodGen.repr)
    rpcMethod = ident(procNameStr)

    paramsIdent = genSym(nskVar, "sigilsSlotArgs")
    paramTypeName = ident("RpcType" & procNameStr)

  # echo "SLOTS:slot:NAME: ", p.name(), " => ", procNameStr, " genname: ", rpcMethodGen
  # echo "SLOTS:paramTypeName:NAME: ", paramTypeName
  # echo "SLOTS:generic: ", genericParams.treeRepr
  # echo "SLOTS: rpcMethodGen:hash: ", rpcMethodGen.symBodyHash()
  # echo "SLOTS: rpcMethodGen:signatureHash: ", rpcMethodGen.signatureHash()

  var
    # process the argument types
    paramTypes = mkParamsType(paramsIdent, paramTypeName, parameters, genericParams)

    procBody =
      if body.kind == nnkStmtList:
        body
      elif body.kind == nnkEmpty:
        body
      else:
        body.body

  let
    contextType = firstType
    kd = ident "kd"
    tp = ident "tp"

  var signalTyp = nnkTupleConstr.newTree()
  for i in 2 ..< params.len:
    signalTyp.add params[i][1]
  if params.len == 2:
    # signalTyp = bindSym"void"
    signalTyp = quote:
      tuple[]

  # Create the proc's that hold the users code
  if not isSignal:
    let rmCall = nnkCall.newTree(rpcMethodGen)
    for param in parameters:
      rmCall.add param[0]

    # If the original proc has a body, emit a full definition.
    # If it's a forward declaration (no body), also emit a matching
    # declaration so wrappers can reference it and later
    # implementations can define it.
    if body.kind == nnkStmtList:
      let rm = quote:
        proc `rpcMethod`() {.nimcall.} =
          `procBody`

      for param in parameters:
        rm[3].add param
      result.add rm
    else:
      # Forward declaration: emit a prototype so the symbol exists
      # and wrappers can call it before a later implementation.
      let fwd = quote:
        proc `rpcMethod`() {.nimcall.}

      for param in parameters:
        fwd[3].add param
      result.add fwd

    var rpcType = paramTypeName.copyNimTree()
    if isGeneric:
      rpcType = nnkBracketExpr.newTree(paramTypeName)
      for arg in genericParams:
        rpcType.add arg

    # Create the rpc wrapper procs
    let objId = genSym(nskLet, "sigilsSlotObj")
    var tupTyp = nnkTupleConstr.newTree()
    for pt in paramTypes[0][^1]:
      tupTyp.add pt[1]
    if tupTyp.len() == 0:
      tupTyp = nnkTupleTy.newTree()
    let mcall = nnkCall.newTree(rpcMethod)
    mcall.add(objId)
    var argIdx = 0
    for param in parameters[1 ..^ 1]:
      discard param
      mcall.add nnkBracketExpr.newTree(paramsIdent, newIntLitNode(argIdx))
      argIdx.inc()

    let localArgsIdent = genSym(nskLet, "sigilsLocalSlotArgs")
    let localMcall = nnkCall.newTree(rpcMethod)
    localMcall.add(objId)
    var localArgIdx = 0
    for param in parameters[1 ..^ 1]:
      discard param
      localMcall.add nnkBracketExpr.newTree(
        nnkBracketExpr.newTree(localArgsIdent),
        newIntLitNode(localArgIdx)
      )
      localArgIdx.inc()

    let agentSlotImpl = quote:
      proc slot(context: Agent, params: SigilParams) {.nimcall.} =
        if context == nil:
          raise newException(ValueError, "bad value")
        let `objId` = `contextType`(context)
        if `objId` == nil:
          raise newException(ConversionError, "bad cast")
        when `tupTyp` isnot tuple[]:
          var `paramsIdent`: `tupTyp`
          rpcUnpack(`paramsIdent`, params)
        `mcall`

    let directSlotImpl = quote:
      proc directSlot(context: Agent, rawArgs: pointer) {.nimcall.} =
        if context == nil:
          raise newException(ValueError, "bad value")
        let `objId` = `contextType`(context)
        if `objId` == nil:
          raise newException(ConversionError, "bad cast")
        when `tupTyp` isnot tuple[]:
          let `localArgsIdent` = cast[ptr `tupTyp`](rawArgs)
        `localMcall`

    let procTyp = quote:
      proc() {.nimcall.}
    procTyp.params = params.copyNimTree()

    result.add quote do:
      when not compiles(`rpcMethod`(`contextType`)):
        proc `rpcMethod`(
            `kd`: typedesc[SignalTypes], `tp`: typedesc[`contextType`]
        ): `signalTyp` =
          discard

        proc `rpcMethod`(`tp`: typedesc[`contextType`]): AgentProcTy[`signalTyp`] =
          `agentSlotImpl`
          slot

        proc `rpcMethod`(
            `kd`: typedesc[LocalSignalTypes], `tp`: typedesc[`contextType`]
        ): LocalAgentProcTy[`signalTyp`] =
          `directSlotImpl`
          directSlot

    result.updateProcsSig(isPublic, genericParams, procLineInfo)
  elif isSignal:
    var construct = nnkTupleConstr.newTree()
    for param in parameters[1 ..^ 1]:
      construct.add param[0]
    let
      objId = newIdentNode("__sigilsSignalSource")
      signalArgsIdent = newIdentNode("__sigilsSignalArgs")

    result.add quote do:
      proc `rpcMethod`(
          `objId`: `firstType`
      ): SigilLocalCall[`firstType`, typeof(`construct`)] =
        var `signalArgsIdent` = `construct`
        const name: SigilName = toSigilName(`signalName`)
        result = SigilLocalCall[`firstType`, typeof(`signalArgsIdent`)](
          source: `objId`,
          procName: name,
          origin: `objId`.getSigilId(),
          args: ensureMove `signalArgsIdent`
        )

    for param in parameters[1 ..^ 1]:
      result[^1][3].add param

    result.add quote do:
      proc `rpcMethod`(
          `objId`: WeakRef[`firstType`]
      ): SigilLocalCall[WeakRef[`firstType`], typeof(`construct`)] =
        var `signalArgsIdent` = `construct`
        const name: SigilName = toSigilName(`signalName`)
        result = SigilLocalCall[WeakRef[`firstType`], typeof(
            `signalArgsIdent`)](
          source: `objId`,
          procName: name,
          origin: `objId`.getSigilId(),
          args: ensureMove `signalArgsIdent`
        )

    for param in parameters[1 ..^ 1]:
      result[^1][3].add param

    result.add quote do:
      proc `rpcMethod`(
          `kd`: typedesc[SignalTypes], `tp`: typedesc[`contextType`]
      ): `signalTyp` =
        discard

    result.updateProcsSig(isPublic, genericParams, procLineInfo)

  var gens: seq[string]
  for gen in genericParams:
    gens.add gen[0].strVal

  # echo "slot: "
  # echo result.lispRepr

  when SigilDebugSlots != "":
    if procNameStr in SigilDebugSlots:
      echo "slot:repr: isSignal: ", isSignal
      echo result.repr

template slot*(p: untyped): untyped =
  rpcImpl(p, nil, nil)

template signal*(p: untyped): untyped =
  rpcImpl(p, "signal", nil)
