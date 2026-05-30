import std/[macros, options, strutils, tables]

import agents

export agents
export options

type
  Selector*[A, R] = object
    ## A typed runtime method name.
    name*: SigilName

  ProtocolRequirement* = object
    ## A selector requirement declared by a dynamic protocol.
    selector*: SigilName
    signature*: string
    required*: bool

  SelectorMethod* = object
    ## A selector paired with a dynamic implementation for batch installs.
    selector*: SigilName
    implementation*: DynamicMethod

  SigilProtocol* = object
    ## A named runtime contract made of required and optional selectors.
    name*: SigilName
    requirements*: seq[ProtocolRequirement]

  ProtocolImplementation* = object
    ## A protocol paired with dynamic methods implementing its selectors.
    protocol*: SigilProtocol
    methods*: seq[SelectorMethod]

  SelectorDefaultArg = object

  UnhandledSelectorError* = object of CatchableError
    ## Raised by required selector sends when no responder handles the selector.

  ProtocolConformanceError* = object of CatchableError
    ## Raised when explicitly adopting a protocol whose required selectors are missing.

  Invocation* = object
    ## Runtime call context passed through dynamic selector dispatch.
    selector*: SigilName
    params*: SigilParams
    result*: SigilParams
    handled*: bool

  ForwardingTarget* = proc(
    self: DynamicAgent, selector: SigilName
  ): DynamicAgent {.closure.}

  ForwardInvocation* = proc(
    self: DynamicAgent, invocation: var Invocation
  ): bool {.closure.}

  ResolveMethod* = proc(
    self: DynamicAgent, selector: SigilName
  ): bool {.closure.}

  DynamicAgent* = ref object of Agent
    methods: Table[SigilName, seq[DynamicMethod]]
    nextResponder: WeakRef[DynamicAgent]
    adoptedProtocols: seq[SigilName]
    forwardingTargetHandler: ForwardingTarget
    forwardInvocationHandler: ForwardInvocation
    resolveMethodHandler: ResolveMethod

  DynamicMethod* = proc(
    self: DynamicAgent, invocation: var Invocation
  ) {.closure.}

  AroundMethod* = proc(
    self: DynamicAgent, invocation: var Invocation, next: DynamicMethod
  ) {.closure.}

  SwizzleToken* = object
    owner: WeakRef[DynamicAgent]
    selector: SigilName
    depth: int

proc initSelector*[A, R](name: static string): Selector[A, R] =
  result.name = toSigilName(name)

proc initSelector*[A, R](name: string): Selector[A, R] =
  result.name = toSigilName(name)

proc selector*[A, R](name: static string): Selector[A, R] =
  initSelector[A, R](name)

proc selector*[A, R](name: string): Selector[A, R] =
  initSelector[A, R](name)

proc selectorName*[A, R](selector: Selector[A, R]): SigilName =
  selector.name

proc requirement*[A, R](
    selector: Selector[A, R], required = true, signature = ""
): ProtocolRequirement =
  result = ProtocolRequirement(
    selector: selector.name,
    signature: signature,
    required: required,
  )

proc initSelectorMethod*[A, R](
    selector: Selector[A, R], implementation: DynamicMethod
): SelectorMethod =
  result = SelectorMethod(
    selector: selector.name,
    implementation: implementation,
  )

proc selectorMethod*[A, R](
    selector: Selector[A, R], implementation: DynamicMethod
): SelectorMethod =
  initSelectorMethod(selector, implementation)

proc `=>`*[A, R](
    selector: Selector[A, R], implementation: DynamicMethod
): SelectorMethod =
  initSelectorMethod(selector, implementation)

proc initProtocol*(
    name: static string, requirements: openArray[ProtocolRequirement]
): SigilProtocol =
  result = SigilProtocol(
    name: toSigilName(name),
    requirements: @requirements,
  )

proc initProtocol*(
    name: string, requirements: openArray[ProtocolRequirement]
): SigilProtocol =
  result = SigilProtocol(
    name: toSigilName(name),
    requirements: @requirements,
  )

proc containsRequirement(
    requirements: openArray[ProtocolRequirement], selector: SigilName
): bool =
  for req in requirements:
    if req.selector == selector:
      return true

proc composeRequirements*(
    protocols: openArray[SigilProtocol],
    requirements: openArray[ProtocolRequirement],
): seq[ProtocolRequirement] =
  ## Merge inherited and local protocol requirements, keeping the first occurrence.
  for protocol in protocols:
    for req in protocol.requirements:
      if not result.containsRequirement(req.selector):
        result.add req
  for req in requirements:
    if not result.containsRequirement(req.selector):
      result.add req

proc initProtocol*(
    name: static string,
    protocols: openArray[SigilProtocol],
    requirements: openArray[ProtocolRequirement],
): SigilProtocol =
  result = SigilProtocol(
    name: toSigilName(name),
    requirements: composeRequirements(protocols, requirements),
  )

proc initProtocol*(
    name: string,
    protocols: openArray[SigilProtocol],
    requirements: openArray[ProtocolRequirement],
): SigilProtocol =
  result = SigilProtocol(
    name: toSigilName(name),
    requirements: composeRequirements(protocols, requirements),
  )

proc initProtocolImplementation*(
    protocol: SigilProtocol, methods: openArray[SelectorMethod]
): ProtocolImplementation =
  result = ProtocolImplementation(
    protocol: protocol,
    methods: @methods,
  )

template selectorDefaultArg(): SelectorDefaultArg =
  SelectorDefaultArg()

proc selectorIdentName(node: NimNode): string =
  if node.kind == nnkPostfix and node.len == 2 and node[0].eqIdent("*"):
    result = node[1].strVal
  elif node.kind in {nnkStrLit .. nnkTripleStrLit}:
    let value = node.strVal
    if value.len > 0 and value[^1] == '*':
      result = value[0 .. ^2]
    else:
      result = value
  else:
    result = node.strVal

proc selectorIdent(name: string, exported: bool): NimNode =
  if exported:
    result = nnkPostfix.newTree(ident"*", ident(name))
  else:
    result = ident(name)

proc setterIdentName(name: string): string =
  if name.len == 0:
    return "set"
  result = "set" & name
  result[3] = result[3].toUpperAscii

proc propertyMethod(
    name: NimNode, valueType: NimNode, setter = false
): NimNode =
  let
    propertyName = selectorIdentName(name)
    methodName =
      if setter:
        selectorIdent(setterIdentName(propertyName), true)
      else:
        selectorIdent(propertyName, true)
    params =
      if setter:
        nnkFormalParams.newTree(
          newEmptyNode(),
          newIdentDefs(ident"value", valueType.copyNimTree()),
        )
      else:
        nnkFormalParams.newTree(valueType.copyNimTree())

  result = nnkMethodDef.newTree(
    methodName,
    newEmptyNode(),
    newEmptyNode(),
    params,
    newEmptyNode(),
    newEmptyNode(),
    newEmptyNode(),
  )

proc propertyMethods(name: NimNode, valueType: NimNode): seq[NimNode] =
  result.add propertyMethod(name, valueType)
  result.add propertyMethod(name, valueType, setter = true)

proc protocolPropertyMethods(item: NimNode): seq[NimNode] =
  if item.kind != nnkCommand or item.len < 2 or not item[0].eqIdent("property"):
    return

  if item.len == 2 and item[1].kind == nnkInfix and item[1].len == 3 and
      item[1][0].eqIdent("->"):
    return propertyMethods(item[1][1], item[1][2])

  error("property declarations use: property name -> Type", item)

proc hasPragma(node: NimNode, name: string): bool =
  if node.kind != nnkPragma:
    return false
  for item in node:
    if item.kind == nnkIdent and item.eqIdent(name):
      return true

proc stripPragma(node: NimNode, name: string): NimNode =
  result = node.copyNimTree()
  if result.kind != nnkPragma:
    return

  let pragmas = nnkPragma.newTree()
  for item in result:
    if item.kind == nnkIdent and item.eqIdent(name):
      continue
    pragmas.add item

  if pragmas.len == 0:
    result = newEmptyNode()
  else:
    result = pragmas

proc methodIsOptional(node: NimNode): bool =
  node.kind == nnkMethodDef and node[4].hasPragma("optional")

proc selectorArgsType(params: NimNode, firstArg: int): NimNode =
  if params.len == firstArg:
    return nnkTupleTy.newTree()
  if params.len == firstArg + 1 and params[firstArg].kind == nnkIdentDefs and
      params[firstArg].len == 3:
    return params[firstArg][1].copyNimTree()

  result = nnkTupleTy.newTree()
  for idx in firstArg ..< params.len:
    let arg = params[idx]
    if arg.kind != nnkIdentDefs:
      error("selector arguments must be named parameters", arg)
    let argType = arg[^2]
    for nameIdx in 0 ..< arg.len - 2:
      result.add newIdentDefs(arg[nameIdx].copyNimTree(), argType.copyNimTree())

proc selectorCallArgs(params: NimNode, firstArg: int, argsIdent: NimNode): seq[NimNode] =
  if params.len == firstArg:
    return
  if params.len == firstArg + 1 and params[firstArg].kind == nnkIdentDefs and
      params[firstArg].len == 3:
    result.add argsIdent
    return

  for idx in firstArg ..< params.len:
    let arg = params[idx]
    for nameIdx in 0 ..< arg.len - 2:
      result.add nnkDotExpr.newTree(argsIdent, arg[nameIdx].copyNimTree())

proc selectorDirectArgs(params: NimNode, firstArg: int): NimNode =
  if params.len == firstArg:
    return nnkTupleConstr.newTree()
  if params.len == firstArg + 1 and params[firstArg].kind == nnkIdentDefs and
      params[firstArg].len == 3:
    return params[firstArg][0].copyNimTree()

  result = nnkTupleConstr.newTree()
  for idx in firstArg ..< params.len:
    let arg = params[idx]
    for nameIdx in 0 ..< arg.len - 2:
      let name = arg[nameIdx].copyNimTree()
      result.add nnkExprColonExpr.newTree(name, name)

proc selectorDirectParams(params: NimNode, firstArg: int,
    selfIdent: NimNode): NimNode =
  let defaultArg = newCall(bindSym"selectorDefaultArg")
  result = nnkFormalParams.newTree(ident"untyped")
  result.add newIdentDefs(
    selfIdent,
    ident"untyped",
    defaultArg,
  )

  for idx in firstArg ..< params.len:
    let arg = params[idx]
    if arg.kind != nnkIdentDefs:
      error("selector arguments must be named parameters", arg)
    for nameIdx in 0 ..< arg.len - 2:
      result.add newIdentDefs(
        arg[nameIdx].copyNimTree(),
        ident"untyped",
        defaultArg.copyNimTree(),
      )

proc selectorDirectCallArgs(params: NimNode, firstArg: int,
    selfIdent: NimNode): seq[NimNode] =
  result.add selfIdent
  for idx in firstArg ..< params.len:
    let arg = params[idx]
    for nameIdx in 0 ..< arg.len - 2:
      result.add arg[nameIdx].copyNimTree()

proc selectorPragma(node: NimNode): NimNode =
  result = node.copyNimTree()
  result[4] = result[4].stripPragma("optional")
  if result[4].kind == nnkEmpty:
    result[4] = nnkPragma.newTree(ident"selector")
  else:
    result[4].add ident"selector"

macro selectorClosureImpl(selector: typed, blk: typed): untyped =
  ## Build a DynamicMethod from a typed receiver closure.
  if blk.kind notin {
    nnkLambda,
    nnkDo,
    nnkProcDef,
    nnkMethodDef,
    nnkFuncDef,
  }:
    return quote do:
      DynamicMethod(`blk`)

  var closure = blk.copyNimTree()
  let params = closure.params

  if params.len < 2:
    error("selector closure methods must take a receiver", blk)
  if params[1].kind != nnkIdentDefs or params[1].len != 3:
    error("selector closure receiver must be a single named parameter", params[1])
  if params[1][1].kind == nnkEmpty:
    error("selector closure receiver must be typed", params[1])

  let
    retType =
      if params[0].kind == nnkEmpty:
        nnkTupleTy.newTree()
      else:
        params[0].copyNimTree()
    receiverType = params[1][1].copyNimTree()
    argsType = selectorArgsType(params, 2)
    callback = genSym(nskLet, "selectorCallback")
    dynMethod = genSym(nskLet, "selectorMethod")
    selectorType = genSym(nskVar, "selectorType")
    closureSelectorType = genSym(nskVar, "closureSelectorType")
    dynSelf = genSym(nskParam, "self")
    receiver = genSym(nskLet, "receiver")
    invocation = genSym(nskParam, "invocation")
    argsIdent = genSym(nskVar, "args")
    call = nnkCall.newTree(callback)

  call.add receiver
  for arg in selectorCallArgs(params, 2, argsIdent):
    call.add arg

  let dispatchBody =
    if argsType.kind == nnkTupleTy and argsType.len == 0:
      if retType.kind == nnkTupleTy and retType.len == 0:
        quote do:
          `call`
          `invocation`.setResult(())
      else:
        quote do:
          `invocation`.setResult(`call`)
    elif retType.kind == nnkTupleTy and retType.len == 0:
      quote do:
        var `argsIdent`: `argsType`
        rpcUnpack(`argsIdent`, `invocation`.params)
        `call`
        `invocation`.setResult(())
    else:
      quote do:
        var `argsIdent`: `argsType`
        rpcUnpack(`argsIdent`, `invocation`.params)
        `invocation`.setResult(`call`)

  result = quote do:
    block:
      let `callback` = `blk`
      var `selectorType` {.used.}: typeof(`selector`)
      var `closureSelectorType` {.used.}: Selector[`argsType`, `retType`]

      when compiles(`selectorType` = `closureSelectorType`):
        discard
      else:
        `selectorType` = `closureSelectorType`

      let `dynMethod`: DynamicMethod = proc(
          `dynSelf`: DynamicAgent, `invocation`: var Invocation
      ) =
        if `dynSelf` == nil:
          raise newException(ValueError, "bad value")
        let `receiver` = `receiverType`(`dynSelf`)
        if `receiver` == nil:
          raise newException(ConversionError, "bad cast")
        `dispatchBody`

      `dynMethod`

macro selectorImpl(p: untyped): untyped =
  if p.kind != nnkMethodDef:
    error("selector pragma can only be used on a method", p)

  let
    selectorName = newStrLitNode(selectorIdentName(p[0]))
    params = p[3]
    retType =
      if params[0].kind == nnkEmpty:
        nnkTupleTy.newTree()
      else:
        params[0].copyNimTree()

  if p[6].kind == nnkEmpty:
    let
      selectorProc = p[0].copyNimTree()
      selectorValueProc = genSym(nskTemplate, selectorIdentName(p[0]) & "Selector")
      directProc = genSym(nskProc, selectorIdentName(p[0]) & "Send")
      argsType = selectorArgsType(params, 1)
      dynSelf = genSym(nskParam, "self")
      directParams = params.copyNimTree()
      directSelf = genSym(nskParam, "self")
      directArgs = selectorDirectArgs(params, 1)
      publicParams = selectorDirectParams(params, 1, dynSelf)
      directCall = nnkCall.newTree(directProc)
      selectorValue = newCall(selectorValueProc)

    directParams.insert(
      1,
      newIdentDefs(directSelf, bindSym"DynamicAgent"),
    )
    for arg in selectorDirectCallArgs(params, 1, dynSelf):
      directCall.add arg

    let directBody =
      if retType.kind == nnkTupleTy and retType.len == 0:
        quote do:
          discard `directSelf`.send(`selectorValue`, `directArgs`)
      else:
        quote do:
          result = `directSelf`.send(`selectorValue`, `directArgs`)

    let selectorValueDef = quote do:
      template `selectorValueProc`(): untyped =
        initSelector[`argsType`, `retType`](`selectorName`)

    let directDef = quote do:
      proc `directProc`() =
        `directBody`
    directDef[3] = directParams

    let selectorBody = quote do:
      when `dynSelf` is SelectorDefaultArg:
        `selectorValue`
      else:
        `directCall`
    let selectorDef = nnkTemplateDef.newTree(
      selectorProc,
      newEmptyNode(),
      newEmptyNode(),
      publicParams,
      newEmptyNode(),
      newEmptyNode(),
      selectorBody,
    )
    result = newStmtList(selectorValueDef, directDef, selectorDef)
  else:
    if params.len < 2:
      error("selector method implementations must take a receiver", params)
    if params[1].kind != nnkIdentDefs or params[1].len != 3:
      error("selector method receiver must be a single named parameter", params[1])

    let
      dynProc = p[0].copyNimTree()
      implProc = genSym(nskProc, selectorIdentName(p[0]) & "Impl")
      implParams = params.copyNimTree()
      body = p[6].copyNimTree()
      receiverName = params[1][0].copyNimTree()
      receiverType = params[1][1].copyNimTree()
      argsType = selectorArgsType(params, 2)
      argsIdent = genSym(nskVar, "args")
      dynSelf = genSym(nskParam, "self")
      invocation = genSym(nskParam, "invocation")
      call = nnkCall.newTree(implProc)

    call.add(receiverName)
    for arg in selectorCallArgs(params, 2, argsIdent):
      call.add arg

    let implDef = quote do:
      proc `implProc`() =
        `body`
    implDef[3] = implParams

    let dispatchBody =
      if argsType.kind == nnkTupleTy and argsType.len == 0:
        if retType.kind == nnkTupleTy and retType.len == 0:
          quote do:
            `implProc`(`receiverName`)
            `invocation`.setResult(())
        else:
          quote do:
            `invocation`.setResult(`implProc`(`receiverName`))
      elif retType.kind == nnkTupleTy and retType.len == 0:
        quote do:
          var `argsIdent`: `argsType`
          rpcUnpack(`argsIdent`, `invocation`.params)
          `call`
          `invocation`.setResult(())
      else:
        quote do:
          var `argsIdent`: `argsType`
          rpcUnpack(`argsIdent`, `invocation`.params)
          `invocation`.setResult(`call`)

    result = newStmtList()
    result.add implDef
    result.add quote do:
      proc `dynProc`(`dynSelf`: DynamicAgent, `invocation`: var Invocation) =
        if `dynSelf` == nil:
          raise newException(ValueError, "bad value")
        let `receiverName` = `receiverType`(`dynSelf`)
        if `receiverName` == nil:
          raise newException(ConversionError, "bad cast")
        `dispatchBody`

template selector*(p: untyped): untyped =
  selectorImpl(p)

macro property*(spec: untyped): untyped =
  ## Declare getter and setter selectors for a property.
  if spec.kind != nnkInfix or spec.len != 3 or not spec[0].eqIdent("->"):
    error("property declarations use: property name -> Type", spec)

  result = newStmtList()
  for item in propertyMethods(spec[1], spec[2]):
    result.add selectorPragma(item)

proc implementMethodBinding(item: NimNode): tuple[defs: seq[NimNode],
    binding: NimNode] =
  if item.kind != nnkMethodDef:
    error("protocol implementations must contain method declarations", item)
  if item[6].kind == nnkEmpty:
    error("protocol implementation methods must have implementations", item)

  let params = item[3]
  if params.len < 2:
    error("protocol implementation methods must take a receiver", params)
  if params[1].kind != nnkIdentDefs or params[1].len != 3:
    error("protocol implementation receiver must be a single named parameter",
        params[1])

  let
    selectorName = ident(selectorIdentName(item[0]))
    implProc = genSym(nskProc, selectorIdentName(item[0]) & "Impl")
    dynProc = genSym(nskProc, selectorIdentName(item[0]) & "Dynamic")
    implParams = params.copyNimTree()
    retType =
      if params[0].kind == nnkEmpty:
        nnkTupleTy.newTree()
      else:
        params[0].copyNimTree()
    body = item[6].copyNimTree()
    receiverName = params[1][0].copyNimTree()
    receiverType = params[1][1].copyNimTree()
    argsType = selectorArgsType(params, 2)
    argsIdent = genSym(nskVar, "args")
    dynSelf = genSym(nskParam, "self")
    invocation = genSym(nskParam, "invocation")
    call = nnkCall.newTree(implProc)

  call.add receiverName
  for arg in selectorCallArgs(params, 2, argsIdent):
    call.add arg

  let implDef = quote do:
    proc `implProc`() =
      `body`
  implDef[3] = implParams

  let dispatchBody =
    if argsType.kind == nnkTupleTy and argsType.len == 0:
      if retType.kind == nnkTupleTy and retType.len == 0:
        quote do:
          `implProc`(`receiverName`)
          `invocation`.setResult(())
      else:
        quote do:
          `invocation`.setResult(`implProc`(`receiverName`))
    elif retType.kind == nnkTupleTy and retType.len == 0:
      quote do:
        var `argsIdent`: `argsType`
        rpcUnpack(`argsIdent`, `invocation`.params)
        `call`
        `invocation`.setResult(())
    else:
      quote do:
        var `argsIdent`: `argsType`
        rpcUnpack(`argsIdent`, `invocation`.params)
        `invocation`.setResult(`call`)

  let dynDef = quote do:
    proc `dynProc`(`dynSelf`: DynamicAgent, `invocation`: var Invocation) =
      if `dynSelf` == nil:
        raise newException(ValueError, "bad value")
      let `receiverName` = `receiverType`(`dynSelf`)
      if `receiverName` == nil:
        raise newException(ConversionError, "bad cast")
      `dispatchBody`

  result.defs = @[implDef, dynDef]
  result.binding = newCall(bindSym"selectorMethod", selectorName, dynProc)

proc implementBlock(
    protocol: NimNode,
    body: NimNode,
    receiver: NimNode = nil,
    allowProperties = false,
): NimNode =
  var
    defs: seq[NimNode]
    bindings: seq[NimNode]

  for item in body:
    if item.protocolPropertyMethods().len > 0:
      if not allowProperties:
        error("protocol implementations must contain method declarations", item)
    else:
      let binding = implementMethodBinding(item)
      defs.add binding.defs
      bindings.add binding.binding

  let methods = nnkBracket.newTree(bindings)
  let value =
    if receiver.isNil:
      newCall(bindSym"initProtocolImplementation", protocol.copyNimTree(), methods)
    else:
      newCall(
        nnkDotExpr.newTree(receiver.copyNimTree(), ident"replaceMethods"),
        protocol.copyNimTree(),
        methods,
      )

  let stmts = newStmtList()
  for item in defs:
    stmts.add item
  stmts.add value

  result = nnkBlockStmt.newTree(newEmptyNode(), stmts)

proc implementVariant(variant: NimNode, protocol: NimNode,
    body: NimNode): NimNode =
  let
    variantType = variant.copyNimTree()
    variantTypeUse = ident(selectorIdentName(variant))
    implementation = implementBlock(protocol, body)
  result = quote do:
    type `variantType` = object

    proc init*(_: typedesc[`variantTypeUse`]): ProtocolImplementation =
      `implementation`

proc protocolRequirementMethod(item: NimNode, firstArg: int): NimNode =
  result = item.copyNimTree()
  let params = item[3]
  if params.len < firstArg:
    error("protocol implementation methods must take a receiver", params)

  if firstArg > 1:
    if params[1].kind != nnkIdentDefs or params[1].len != 3:
      error("protocol implementation receiver must be a single named parameter",
          params[1])

    let requirementParams = nnkFormalParams.newTree(params[0].copyNimTree())
    for idx in firstArg ..< params.len:
      requirementParams.add params[idx].copyNimTree()
    result[3] = requirementParams

  result[4] = result[4].stripPragma("optional")
  result[6] = newEmptyNode()

proc validateProtocolReceiver(item: NimNode, receiver: NimNode) =
  let params = item[3]
  if params.len < 2:
    error("protocol implementation methods must take a receiver", params)
  if params[1].kind != nnkIdentDefs or params[1].len != 3:
    error("protocol implementation receiver must be a single named parameter",
        params[1])
  if params[1][1].repr != receiver.repr:
    error("protocol implementation receiver must be " & receiver.repr, params[1][1])

proc addProtocolRequirement(
    selectorDecls: var seq[NimNode],
    reqs: var seq[NimNode],
    selectors: var seq[string],
    item: NimNode,
    firstArg: int,
    required: bool,
) =
  if item.kind != nnkMethodDef:
    error("protocol requirements must be method declarations", item)

  let selectorName = selectorIdentName(item[0])
  if selectorName in selectors:
    return
  selectors.add selectorName

  let requirementMethod = protocolRequirementMethod(item, firstArg)
  selectorDecls.add selectorPragma(requirementMethod)
  reqs.add newCall(
    bindSym"requirement",
    ident(selectorName),
    newLit(required),
    newLit(requirementMethod.repr),
  )

proc protocolDeclaration(
    name: NimNode,
    body: NimNode,
    firstArg = 1,
    receiver: NimNode = nil,
    inherited: openArray[NimNode] = [],
): NimNode =
  let protocolName = newStrLitNode(selectorIdentName(name))
  var
    selectorDecls: seq[NimNode]
    reqs: seq[NimNode]
    selectors: seq[string]

  for section in body:
    let propertyDecls = section.protocolPropertyMethods()
    if propertyDecls.len > 0:
      for propertyDecl in propertyDecls:
        addProtocolRequirement(
          selectorDecls,
          reqs,
          selectors,
          propertyDecl,
          1,
          not propertyDecl.methodIsOptional,
        )
    elif section.kind == nnkMethodDef:
      if not receiver.isNil:
        validateProtocolReceiver(section, receiver)
      elif section[6].kind != nnkEmpty:
        error("protocol requirements cannot have implementations", section)

      addProtocolRequirement(
        selectorDecls,
        reqs,
        selectors,
        section,
        firstArg,
        not section.methodIsOptional,
      )
    else:
      error("protocol bodies must contain method declarations", section)

  result = newStmtList()
  for selectorDecl in selectorDecls:
    result.add selectorDecl

  let protocolCall =
    if inherited.len == 0:
      newCall(
        bindSym"initProtocol",
        protocolName,
        nnkBracket.newTree(reqs),
      )
    else:
      newCall(
        bindSym"initProtocol",
        protocolName,
        nnkBracket.newTree(inherited),
        nnkBracket.newTree(reqs),
      )

  result.add newLetStmt(name.copyNimTree(), protocolCall)

proc implementProtocolForReceiver(
    protocol: NimNode, receiver: NimNode, body: NimNode
): NimNode =
  let
    protocolDecl = protocolDeclaration(protocol, body, 2, receiver)
    implementation = implementBlock(protocol, body, allowProperties = true)
    receiverType = receiver.copyNimTree()

  result = quote do:
    `protocolDecl`

    proc proto*(_: typedesc[`receiverType`]): ProtocolImplementation =
      `implementation`

proc protocolIncludes(name: NimNode): tuple[matched: bool, protocol: NimNode,
    inherited: seq[NimNode]] =
  if name.kind == nnkCommand and name.len == 2 and
      name[1].kind == nnkCommand and name[1].len == 2 and
      name[1][0].eqIdent("includes"):
    result.matched = true
    result.protocol = name[0]
    result.inherited.add name[1][1]

macro protocol*(name: untyped, body: untyped): untyped =
  ## Declare a protocol or a named implementation variant for a protocol.
  if name.kind == nnkInfix and name.len == 3 and name[0].eqIdent("of"):
    return implementVariant(name[1], name[2], body)
  if name.kind == nnkInfix and name.len == 3 and name[0].eqIdent("from"):
    return implementProtocolForReceiver(name[1], name[2], body)
  let includes = protocolIncludes(name)
  if includes.matched:
    return protocolDeclaration(includes.protocol, body,
        inherited = includes.inherited)
  if name.kind == nnkCommand and name.len == 2 and
      name[1].kind == nnkCommand and name[1].len == 2 and
      name[1][0].kind == nnkAccQuoted and
      name[1][0].len == 1 and name[1][0][0].eqIdent("for"):
    return implementProtocolForReceiver(name[0], name[1][1], body)

  protocolDeclaration(name, body)

macro protocol*(name: untyped, receiver: untyped, body: untyped): untyped =
  ## Declare a protocol and its default implementation for a receiver type.
  implementProtocolForReceiver(name, receiver, body)

macro implement*(protocol: untyped, body: untyped): untyped =
  ## Build a reusable protocol implementation from selector method bodies.
  if protocol.kind == nnkInfix and protocol.len == 3 and protocol[0].eqIdent("of"):
    return implementVariant(protocol[1], protocol[2], body)
  if protocol.kind == nnkCall and protocol.len == 2:
    error("named protocol implementations use: protocol Variant of Protocol:", protocol)

  implementBlock(protocol, body)

macro implement*(receiver: untyped, protocol: untyped, body: untyped): untyped =
  ## Replace methods on a receiver with a protocol implementation block.
  implementBlock(protocol, body, receiver)

proc initInvocation*[A](
    selector: SigilName, args: sink A
): Invocation =
  result = Invocation(
    selector: selector,
    params: rpcPack(ensureMove args),
    handled: false,
  )

proc argsAs*[A](invocation: Invocation, _: typedesc[A]): A =
  rpcUnpack(result, invocation.params)

proc setResult*[R](invocation: var Invocation, value: sink R) =
  invocation.result = rpcPack(ensureMove value)
  invocation.handled = true

proc resultAs*[R](invocation: Invocation, _: typedesc[R]): R =
  rpcUnpack(result, invocation.result)

proc localMethod*(obj: DynamicAgent, selector: SigilName): DynamicMethod =
  ## Return the top local method for a selector, if one is installed.
  if obj.isNil:
    return nil
  if selector notin obj.methods:
    return nil
  let stack = obj.methods[selector]
  if stack.len == 0:
    return nil
  result = stack[^1]

proc localMethod*[A, R](
    obj: DynamicAgent, selector: Selector[A, R]
): DynamicMethod =
  ## Return the top local method for a typed selector, if one is installed.
  obj.localMethod(selector.name)

proc methodFor*(obj: DynamicAgent, selector: SigilName): DynamicMethod =
  ## Return the top local method for a selector, if one is installed.
  obj.localMethod(selector)

proc methodFor*[A, R](
    obj: DynamicAgent, selector: Selector[A, R]
): DynamicMethod =
  ## Return the top local method for a typed selector, if one is installed.
  obj.localMethod(selector)

proc methodStack*(obj: DynamicAgent, selector: SigilName): seq[DynamicMethod] =
  ## Return the local method stack for a selector.
  if obj.isNil or selector notin obj.methods:
    return @[]
  obj.methods[selector]

proc methodStack*[A, R](
    obj: DynamicAgent, selector: Selector[A, R]
): seq[DynamicMethod] =
  ## Return the local method stack for a typed selector.
  obj.methodStack(selector.name)

proc setNextResponder*(obj, responder: DynamicAgent) =
  ## Set the object that receives unhandled selector invocations.
  obj.nextResponder = responder.unsafeWeakRef()

proc nextResponder*(obj: DynamicAgent): DynamicAgent =
  ## Return the object that receives unhandled selector invocations.
  if obj.isNil or obj.nextResponder.isNil:
    return nil
  obj.nextResponder[]

proc clearNextResponder*(obj: DynamicAgent) =
  obj.nextResponder = WeakRef[DynamicAgent]()

proc setForwardingTarget*(obj: DynamicAgent, handler: ForwardingTarget) =
  ## Set a handler that can choose a target for unhandled selectors.
  obj.forwardingTargetHandler = handler

proc clearForwardingTarget*(obj: DynamicAgent) =
  ## Clear the forwarding target handler.
  obj.forwardingTargetHandler = nil

proc setForwardInvocation*(obj: DynamicAgent, handler: ForwardInvocation) =
  ## Set a final invocation forwarding handler for unhandled selectors.
  obj.forwardInvocationHandler = handler

proc clearForwardInvocation*(obj: DynamicAgent) =
  ## Clear the final invocation forwarding handler.
  obj.forwardInvocationHandler = nil

proc setResolveMethod*(obj: DynamicAgent, handler: ResolveMethod) =
  ## Set a handler that may lazily install a method for a selector.
  obj.resolveMethodHandler = handler

proc clearResolveMethod*(obj: DynamicAgent) =
  ## Clear the method resolution handler.
  obj.resolveMethodHandler = nil

proc respondsTo*(obj: DynamicAgent, selector: SigilName): bool =
  if obj.isNil:
    return false
  if not obj.localMethod(selector).isNil:
    return true
  if not obj.forwardingTargetHandler.isNil:
    let target = obj.forwardingTargetHandler(obj, selector)
    if not target.isNil and target != obj and target.respondsTo(selector):
      return true
  if not obj.nextResponder.isNil:
    return obj.nextResponder[].respondsTo(selector)

proc respondsTo*[A, R](obj: DynamicAgent, selector: Selector[A, R]): bool =
  obj.respondsTo(selector.name)

proc requiredRequirements*(protocol: SigilProtocol): seq[ProtocolRequirement] =
  ## Return the required requirements for a protocol.
  for req in protocol.requirements:
    if req.required:
      result.add req

proc optionalRequirements*(protocol: SigilProtocol): seq[ProtocolRequirement] =
  ## Return the optional requirements for a protocol.
  for req in protocol.requirements:
    if not req.required:
      result.add req

proc selectors*(protocol: SigilProtocol): seq[SigilName] =
  ## Return all selector names declared by a protocol.
  for req in protocol.requirements:
    result.add req.selector

proc requiredSelectors*(protocol: SigilProtocol): seq[SigilName] =
  ## Return required selector names declared by a protocol.
  for req in protocol.requirements:
    if req.required:
      result.add req.selector

proc optionalSelectors*(protocol: SigilProtocol): seq[SigilName] =
  ## Return optional selector names declared by a protocol.
  for req in protocol.requirements:
    if not req.required:
      result.add req.selector

proc requirement*(
    protocol: SigilProtocol, selector: SigilName
): Option[ProtocolRequirement] =
  ## Return the protocol requirement for a selector, if present.
  for req in protocol.requirements:
    if req.selector == selector:
      return some(req)

proc requirement*[A, R](
    protocol: SigilProtocol, selector: Selector[A, R]
): Option[ProtocolRequirement] =
  ## Return the protocol requirement for a typed selector, if present.
  protocol.requirement(selector.name)

proc hasRequirement*(protocol: SigilProtocol, selector: SigilName): bool =
  ## Check whether a protocol declares a selector.
  protocol.requirement(selector).isSome

proc hasRequirement*[A, R](
    protocol: SigilProtocol, selector: Selector[A, R]
): bool =
  ## Check whether a protocol declares a typed selector.
  protocol.hasRequirement(selector.name)

proc missingRequirements*(obj: DynamicAgent, protocol: SigilProtocol): seq[
    ProtocolRequirement] =
  ## Return required protocol selectors that this object cannot currently handle.
  for req in protocol.requirements:
    if req.required and not obj.respondsTo(req.selector):
      result.add req

proc containsMethod(methods: openArray[SelectorMethod],
    selector: SigilName): bool =
  for binding in methods:
    if binding.selector == selector:
      return true

proc missingRequirements*(
    protocol: SigilProtocol, methods: openArray[SelectorMethod]
): seq[ProtocolRequirement] =
  ## Return required protocol selectors that are not in a method batch.
  for req in protocol.requirements:
    if req.required and not methods.containsMethod(req.selector):
      result.add req

proc missingRequirements*(
    obj: DynamicAgent,
    protocol: SigilProtocol,
    methods: openArray[SelectorMethod],
): seq[ProtocolRequirement] =
  ## Return required selectors not handled by an object or a planned method batch.
  for req in protocol.requirements:
    if req.required and not methods.containsMethod(req.selector) and
        not obj.respondsTo(req.selector):
      result.add req

proc canConformTo*(obj: DynamicAgent, protocol: SigilProtocol): bool =
  ## Check structural conformance against required protocol selectors.
  obj.missingRequirements(protocol).len == 0

proc canConformTo*(
    obj: DynamicAgent,
    protocol: SigilProtocol,
    methods: openArray[SelectorMethod],
): bool =
  ## Check conformance after applying a planned method batch.
  obj.missingRequirements(protocol, methods).len == 0

proc canImplement*(
    protocol: SigilProtocol, methods: openArray[SelectorMethod]
): bool =
  ## Check whether a method batch contains every required protocol selector.
  protocol.missingRequirements(methods).len == 0

proc hasAdopted*(obj: DynamicAgent, protocol: SigilProtocol): bool =
  ## Check whether this object explicitly adopted the protocol.
  if obj.isNil:
    return false
  protocol.name in obj.adoptedProtocols

proc adoptedProtocols*(obj: DynamicAgent): seq[SigilName] =
  ## Return protocol names explicitly adopted by this object.
  if obj.isNil:
    return @[]
  obj.adoptedProtocols

proc raiseProtocolConformanceError(
    protocol: SigilProtocol, missing: openArray[ProtocolRequirement]
) =
  var message = "cannot adopt protocol " & $protocol.name
  if missing.len > 0:
    message.add "; missing required selector: " & $missing[0].selector
  raise newException(ProtocolConformanceError, message)

proc raiseProtocolConformanceError(obj: DynamicAgent, protocol: SigilProtocol) =
  raiseProtocolConformanceError(protocol, obj.missingRequirements(protocol))

proc adopt*(obj: DynamicAgent, protocol: SigilProtocol): bool {.discardable.} =
  ## Explicitly record protocol conformance after checking required selectors.
  if obj.isNil:
    raiseProtocolConformanceError(obj, protocol)
  if not obj.canConformTo(protocol):
    raiseProtocolConformanceError(obj, protocol)
  if protocol.name notin obj.adoptedProtocols:
    obj.adoptedProtocols.add protocol.name
  result = true

proc unadopt*(obj: DynamicAgent, protocol: SigilProtocol): bool {.discardable.} =
  ## Remove explicit protocol adoption, if present.
  if obj.isNil:
    return false
  for idx, name in obj.adoptedProtocols:
    if name == protocol.name:
      obj.adoptedProtocols.delete(idx)
      return true

proc conformsTo*(obj: DynamicAgent, protocol: SigilProtocol): bool =
  ## Check explicit adoption first, then structural conformance.
  obj.hasAdopted(protocol) or obj.canConformTo(protocol)

proc dispatch*(obj: DynamicAgent, invocation: var Invocation): bool =
  ## Try to handle an invocation locally, then through the responder chain.
  if obj.isNil:
    return false

  var fn = obj.localMethod(invocation.selector)
  if fn.isNil and not obj.resolveMethodHandler.isNil and
      obj.resolveMethodHandler(obj, invocation.selector):
    fn = obj.localMethod(invocation.selector)

  if not fn.isNil:
    fn(obj, invocation)
    if invocation.handled:
      return true

  if not obj.forwardingTargetHandler.isNil:
    let target = obj.forwardingTargetHandler(obj, invocation.selector)
    if not target.isNil and target != obj and target.dispatch(invocation):
      return true

  if not obj.nextResponder.isNil:
    if obj.nextResponder[].dispatch(invocation):
      return true

  if not obj.forwardInvocationHandler.isNil:
    return obj.forwardInvocationHandler(obj, invocation)

proc dispatchLocal*(obj: DynamicAgent, invocation: var Invocation): bool =
  ## Try to handle an invocation without walking the responder chain.
  if obj.isNil:
    return false

  var fn = obj.localMethod(invocation.selector)
  if fn.isNil and not obj.resolveMethodHandler.isNil and
      obj.resolveMethodHandler(obj, invocation.selector):
    fn = obj.localMethod(invocation.selector)

  if not fn.isNil:
    fn(obj, invocation)
    if invocation.handled:
      return true

  if not obj.forwardingTargetHandler.isNil:
    let target = obj.forwardingTargetHandler(obj, invocation.selector)
    if not target.isNil and target != obj and target.dispatchLocal(invocation):
      return true

  if not obj.forwardInvocationHandler.isNil:
    return obj.forwardInvocationHandler(obj, invocation)

proc perform*[A, R](
    obj: DynamicAgent,
    selector: Selector[A, R],
    args: sink A,
    value: var R,
): bool =
  var invocation = initInvocation(selector.name, ensureMove args)
  result = obj.dispatch(invocation)
  if result:
    rpcUnpack(value, invocation.result)

proc performLocal*[A, R](
    obj: DynamicAgent,
    selector: Selector[A, R],
    args: sink A,
    value: var R,
): bool =
  var invocation = initInvocation(selector.name, ensureMove args)
  result = obj.dispatchLocal(invocation)
  if result:
    rpcUnpack(value, invocation.result)

proc perform*[A, R](
    obj: DynamicAgent, selector: Selector[A, R], args: sink A
): Option[R] =
  var value: R
  if obj.perform(selector, ensureMove args, value):
    result = some(value)

proc performLocal*[A, R](
    obj: DynamicAgent, selector: Selector[A, R], args: sink A
): Option[R] =
  var value: R
  if obj.performLocal(selector, ensureMove args, value):
    result = some(value)

proc trySend*[A, R](
    obj: DynamicAgent, selector: Selector[A, R], args: sink A
): Option[R] =
  ## Perform an optional selector send.
  obj.perform(selector, ensureMove args)

proc trySend*[R](obj: DynamicAgent, selector: Selector[tuple[], R]): Option[R] =
  ## Perform an optional zero-argument selector send.
  obj.perform(selector, ())

proc trySendLocal*[A, R](
    obj: DynamicAgent, selector: Selector[A, R], args: sink A
): Option[R] =
  ## Perform an optional selector send without walking the responder chain.
  obj.performLocal(selector, ensureMove args)

proc trySendLocal*[R](obj: DynamicAgent, selector: Selector[tuple[],
    R]): Option[R] =
  ## Perform an optional zero-argument selector send without walking the responder chain.
  obj.performLocal(selector, ())

proc sendIfHandled*[A, R](
    obj: DynamicAgent, selector: Selector[A, R], args: sink A
): bool =
  ## Perform an optional selector send and return whether it was handled.
  var value: R
  obj.perform(selector, ensureMove args, value)

proc sendIfHandled*[R](obj: DynamicAgent, selector: Selector[tuple[], R]): bool =
  ## Perform an optional zero-argument selector send and return whether it was handled.
  var value: R
  obj.perform(selector, (), value)

proc sendLocalIfHandled*[A, R](
    obj: DynamicAgent, selector: Selector[A, R], args: sink A
): bool =
  ## Perform an optional selector send without walking the responder chain.
  var value: R
  obj.performLocal(selector, ensureMove args, value)

proc sendLocalIfHandled*[R](
    obj: DynamicAgent, selector: Selector[tuple[], R]
): bool =
  ## Perform an optional zero-argument selector send without walking the responder chain.
  var value: R
  obj.performLocal(selector, (), value)

proc raiseUnhandledSelector(selector: SigilName) =
  raise newException(UnhandledSelectorError, "unhandled selector: " & $selector)

proc send*[A, R](
    obj: DynamicAgent, selector: Selector[A, R], args: sink A
): R =
  ## Perform a required selector send and raise if no responder handles it.
  if not obj.perform(selector, ensureMove args, result):
    raiseUnhandledSelector(selector.name)

proc toDynamicMethod*[T: DynamicAgent, A, R](
    fn: proc(self: T, args: A): R {.closure.}
): DynamicMethod =
  result = proc(self: DynamicAgent, invocation: var Invocation) =
    if self == nil:
      raise newException(ValueError, "bad value")
    let obj = T(self)
    if obj == nil:
      raise newException(ConversionError, "bad cast")
    let args = invocation.argsAs(A)
    invocation.setResult(fn(obj, args))

proc toDynamicMethod*[T: DynamicAgent, A, R](
    fn: proc(self: T, args: A): R {.nimcall.}
): DynamicMethod =
  result = proc(self: DynamicAgent, invocation: var Invocation) =
    if self == nil:
      raise newException(ValueError, "bad value")
    let obj = T(self)
    if obj == nil:
      raise newException(ConversionError, "bad cast")
    let args = invocation.argsAs(A)
    invocation.setResult(fn(obj, args))

template toDynamicMethod*[A, R](
    selector: Selector[A, R], blk: typed
): DynamicMethod =
  ## Convert a typed receiver closure into a dynamic selector method.
  selectorClosureImpl(selector, blk)

template selectorMethod*[A, R](
    selector: Selector[A, R], blk: typed
): SelectorMethod =
  ## Pair a selector with a typed receiver closure for batch installs.
  initSelectorMethod(selector, selector.toDynamicMethod(blk))

template `=>`*[A, R](
    selector: Selector[A, R], blk: typed
): SelectorMethod =
  selectorMethod(selector, blk)

proc addMethod*[A, R](
    obj: DynamicAgent,
    selector: Selector[A, R],
    fn: DynamicMethod,
): bool =
  ## Add a method only when the object does not already handle the selector.
  if selector.name in obj.methods and obj.methods[selector.name].len > 0:
    return false
  obj.methods[selector.name] = @[fn]
  result = true

template addMethod*[A, R](
    obj: DynamicAgent,
    selector: Selector[A, R],
    blk: typed,
): bool =
  ## Add a typed receiver closure as a selector method.
  obj.addMethod(selector, selector.toDynamicMethod(blk))

proc addMethods*(obj: DynamicAgent, methods: openArray[SelectorMethod]): bool {.
    discardable.} =
  ## Add methods only when none of their selectors already have local handlers.
  for binding in methods:
    if binding.selector in obj.methods and obj.methods[binding.selector].len > 0:
      return false

  for binding in methods:
    obj.methods[binding.selector] = @[binding.implementation]
  result = true

proc replaceMethod*[A, R](
    obj: DynamicAgent,
    selector: Selector[A, R],
    fn: DynamicMethod,
): DynamicMethod {.discardable.} =
  ## Replace the local implementation and return the previous top method, if any.
  result = obj.localMethod(selector.name)
  obj.methods[selector.name] = @[fn]

template replaceMethod*[A, R](
    obj: DynamicAgent,
    selector: Selector[A, R],
    blk: typed,
): DynamicMethod =
  ## Replace the local implementation with a typed receiver closure.
  obj.replaceMethod(selector, selector.toDynamicMethod(blk))

proc replaceMethods*(
    obj: DynamicAgent, methods: openArray[SelectorMethod]
): seq[DynamicMethod] {.discardable.} =
  ## Replace local implementations and return the previous top methods.
  for binding in methods:
    result.add obj.localMethod(binding.selector)
  for binding in methods:
    obj.methods[binding.selector] = @[binding.implementation]

proc removeMethod*(obj: DynamicAgent, selector: SigilName): DynamicMethod {.
    discardable.} =
  ## Remove local methods for a selector and return the previous top method.
  result = obj.localMethod(selector)
  if not obj.isNil and selector in obj.methods:
    obj.methods.del(selector)

proc removeMethod*[A, R](
    obj: DynamicAgent, selector: Selector[A, R]
): DynamicMethod {.discardable.} =
  ## Remove local methods for a typed selector and return the previous top method.
  obj.removeMethod(selector.name)

proc removeMethods*(
    obj: DynamicAgent, methods: openArray[SelectorMethod]
): seq[DynamicMethod] {.discardable.} =
  ## Remove local methods for a method batch and return the previous top methods.
  for binding in methods:
    result.add obj.removeMethod(binding.selector)

proc addMethods*(
    obj: DynamicAgent,
    protocol: SigilProtocol,
    methods: openArray[SelectorMethod],
): bool {.discardable.} =
  ## Add methods, then explicitly adopt a protocol satisfied by the result.
  if not obj.canConformTo(protocol, methods):
    raiseProtocolConformanceError(protocol, obj.missingRequirements(protocol, methods))
  if not obj.addMethods(methods):
    return false
  discard obj.adopt(protocol)
  result = true

proc replaceMethods*(
    obj: DynamicAgent,
    protocol: SigilProtocol,
    methods: openArray[SelectorMethod],
): seq[DynamicMethod] {.discardable.} =
  ## Replace methods, then explicitly adopt a protocol satisfied by the result.
  if not obj.canConformTo(protocol, methods):
    raiseProtocolConformanceError(protocol, obj.missingRequirements(protocol, methods))
  result = obj.replaceMethods(methods)
  discard obj.adopt(protocol)

proc addMethods*(
    obj: DynamicAgent, implementation: ProtocolImplementation
): bool {.discardable.} =
  ## Add a reusable protocol implementation, then adopt its protocol.
  obj.addMethods(implementation.protocol, implementation.methods)

proc replaceMethods*(
    obj: DynamicAgent, implementation: ProtocolImplementation
): seq[DynamicMethod] {.discardable.} =
  ## Replace methods from a reusable protocol implementation, then adopt its protocol.
  obj.replaceMethods(implementation.protocol, implementation.methods)

proc removeMethods*(
    obj: DynamicAgent, protocol: SigilProtocol
): seq[DynamicMethod] {.discardable.} =
  ## Remove local methods for a protocol's selectors, then remove explicit adoption.
  for requirement in protocol.requirements:
    result.add obj.removeMethod(requirement.selector)
  discard obj.unadopt(protocol)

proc removeMethods*(
    obj: DynamicAgent, implementation: ProtocolImplementation
): seq[DynamicMethod] {.discardable.} =
  ## Remove local methods from a reusable protocol implementation.
  result = obj.removeMethods(implementation.methods)
  discard obj.unadopt(implementation.protocol)

proc withProtocol*[T: DynamicAgent](
    obj: T, implementation: ProtocolImplementation
): T {.discardable.} =
  ## Replace methods from a protocol implementation and return the object.
  discard obj.replaceMethods(implementation)
  result = obj

proc withProtocol*[T: DynamicAgent, P](obj: T, _: typedesc[
    P]): T {.discardable.} =
  ## Replace methods from a named protocol implementation and return the object.
  result = obj.withProtocol(P.init())

proc withProto*[T: DynamicAgent](obj: T): T {.discardable.} =
  ## Replace methods with the default protocol implementation and return the object.
  result = obj.withProtocol(T.proto())

proc objectConstructorArg(arg: NimNode): NimNode =
  if arg.kind == nnkExprEqExpr:
    result = nnkExprColonExpr.newTree(
      arg[0].copyNimTree(),
      arg[1].copyNimTree(),
    )
  else:
    result = arg.copyNimTree()

macro newProto*(typ: typedesc, args: varargs[untyped]): untyped =
  ## Create a ref object, install its default protocol implementation, and return it.
  let
    receiverType = typ.copyNimTree()
    newCall = nnkCall.newTree(nnkDotExpr.newTree(
      receiverType.copyNimTree(),
      ident"new",
    ))
    objectCtor = nnkObjConstr.newTree(receiverType.copyNimTree())
    obj = genSym(nskLet, "obj")

  for arg in args:
    newCall.add arg.copyNimTree()
    objectCtor.add objectConstructorArg(arg)

  result = quote do:
    block:
      let `obj` =
        when compiles(`newCall`):
          `newCall`
        else:
          `objectCtor`
      `obj`.withProto()

proc pushMethod*[A, R](
    obj: DynamicAgent,
    selector: Selector[A, R],
    fn: DynamicMethod,
): SwizzleToken =
  ## Push a reversible method override onto the local method stack.
  let stack = obj.methods.getOrDefault(selector.name)
  obj.methods[selector.name] = stack & @[fn]
  result = SwizzleToken(
    owner: obj.unsafeWeakRef(),
    selector: selector.name,
    depth: stack.len,
  )

proc pushMethod*[A, R](
    obj: DynamicAgent,
    selector: Selector[A, R],
    wrapper: AroundMethod,
): SwizzleToken =
  ## Push a reversible wrapper around the current local implementation.
  let stack = obj.methods.getOrDefault(selector.name)
  let previous =
    if stack.len == 0: DynamicMethod(nil)
    else: stack[^1]
  let wrapped: DynamicMethod = proc(
      self: DynamicAgent, invocation: var Invocation
  ) =
    wrapper(self, invocation, previous)

  result = obj.pushMethod(selector, wrapped)

proc pushMethod*[A, R](
    obj: DynamicAgent,
    selector: Selector[A, R],
    wrapper: proc(
      self: DynamicAgent, invocation: var Invocation, next: DynamicMethod
    ) {.nimcall.},
): SwizzleToken =
  let wrapped: AroundMethod = proc(
      self: DynamicAgent, invocation: var Invocation, next: DynamicMethod
  ) =
    wrapper(self, invocation, next)
  result = obj.pushMethod(selector, wrapped)

template pushMethod*[A, R](
    obj: DynamicAgent,
    selector: Selector[A, R],
    blk: typed,
): SwizzleToken =
  ## Push a typed receiver closure as a reversible method override.
  obj.pushMethod(selector, selector.toDynamicMethod(blk))

proc popMethod*(token: SwizzleToken): bool =
  ## Restore a wrapper if it is still the current top method.
  if token.owner.isNil:
    return false

  let obj = token.owner[]
  if token.selector notin obj.methods:
    return false

  var stack = obj.methods[token.selector]
  if stack.len != token.depth + 1:
    return false

  stack.setLen(token.depth)
  if stack.len == 0:
    obj.methods.del(token.selector)
  else:
    obj.methods[token.selector] = stack
  result = true
