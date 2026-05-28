import std/[macros, options, tables]

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

  DynamicAgent* = ref object of Agent
    methods: Table[SigilName, seq[DynamicMethod]]
    nextResponder: WeakRef[DynamicAgent]
    adoptedProtocols: seq[SigilName]

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
  else:
    result = node.strVal

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
    protocol: NimNode, body: NimNode, receiver: NimNode = nil
): NimNode =
  var
    defs: seq[NimNode]
    bindings: seq[NimNode]

  for item in body:
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
    item: NimNode,
    firstArg: int,
    required: bool,
) =
  if item.kind != nnkMethodDef:
    error("protocol requirements must be method declarations", item)

  let requirementMethod = protocolRequirementMethod(item, firstArg)
  selectorDecls.add selectorPragma(requirementMethod)
  reqs.add newCall(
    bindSym"requirement",
    ident(selectorIdentName(item[0])),
    newLit(required),
    newLit(requirementMethod.repr),
  )

proc protocolDeclaration(
    name: NimNode, body: NimNode, firstArg = 1, receiver: NimNode = nil
): NimNode =
  let protocolName = newStrLitNode(selectorIdentName(name))
  var
    selectorDecls: seq[NimNode]
    reqs: seq[NimNode]

  for section in body:
    if section.kind == nnkMethodDef:
      if not receiver.isNil:
        validateProtocolReceiver(section, receiver)
      elif section[6].kind != nnkEmpty:
        error("protocol requirements cannot have implementations", section)

      addProtocolRequirement(
        selectorDecls,
        reqs,
        section,
        firstArg,
        not section.methodIsOptional,
      )
    else:
      error("protocol bodies must contain method declarations", section)

  result = newStmtList()
  for selectorDecl in selectorDecls:
    result.add selectorDecl

  result.add newLetStmt(
    name.copyNimTree(),
    newCall(
      bindSym"initProtocol",
      protocolName,
      nnkBracket.newTree(reqs),
    ),
  )

proc implementProtocolForReceiver(
    protocol: NimNode, receiver: NimNode, body: NimNode
): NimNode =
  let
    protocolDecl = protocolDeclaration(protocol, body, 2, receiver)
    implementation = implementBlock(protocol, body)
    receiverType = receiver.copyNimTree()

  result = quote do:
    `protocolDecl`

    proc proto*(_: typedesc[`receiverType`]): ProtocolImplementation =
      `implementation`

macro protocol*(name: untyped, body: untyped): untyped =
  ## Declare a protocol or a named implementation variant for a protocol.
  if name.kind == nnkInfix and name.len == 3 and name[0].eqIdent("of"):
    return implementVariant(name[1], name[2], body)
  if name.kind == nnkInfix and name.len == 3 and name[0].eqIdent("from"):
    return implementProtocolForReceiver(name[1], name[2], body)
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

proc localMethod(obj: DynamicAgent, selector: SigilName): DynamicMethod =
  if selector notin obj.methods:
    return nil
  let stack = obj.methods[selector]
  if stack.len == 0:
    return nil
  result = stack[^1]

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

proc respondsTo*(obj: DynamicAgent, selector: SigilName): bool =
  if obj.isNil:
    return false
  if not obj.localMethod(selector).isNil:
    return true
  if not obj.nextResponder.isNil:
    return obj.nextResponder[].respondsTo(selector)

proc respondsTo*[A, R](obj: DynamicAgent, selector: Selector[A, R]): bool =
  obj.respondsTo(selector.name)

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

proc conformsTo*(obj: DynamicAgent, protocol: SigilProtocol): bool =
  ## Check explicit adoption first, then structural conformance.
  obj.hasAdopted(protocol) or obj.canConformTo(protocol)

proc dispatch*(obj: DynamicAgent, invocation: var Invocation): bool =
  ## Try to handle an invocation locally, then through the responder chain.
  if obj.isNil:
    return false

  let fn = obj.localMethod(invocation.selector)
  if not fn.isNil:
    fn(obj, invocation)
    return invocation.handled

  if not obj.nextResponder.isNil:
    return obj.nextResponder[].dispatch(invocation)

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

proc perform*[A, R](
    obj: DynamicAgent, selector: Selector[A, R], args: sink A
): Option[R] =
  var value: R
  if obj.perform(selector, ensureMove args, value):
    result = some(value)

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

proc replaceMethods*(
    obj: DynamicAgent, methods: openArray[SelectorMethod]
): seq[DynamicMethod] {.discardable.} =
  ## Replace local implementations and return the previous top methods.
  for binding in methods:
    result.add obj.localMethod(binding.selector)
  for binding in methods:
    obj.methods[binding.selector] = @[binding.implementation]

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

proc withProto*[T: DynamicAgent](obj: T): T {.discardable.} =
  ## Replace methods with the default protocol implementation and return the object.
  discard obj.replaceMethods(T.proto())
  result = obj

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

  obj.methods[selector.name] = stack & @[wrapped]
  result = SwizzleToken(
    owner: obj.unsafeWeakRef(),
    selector: selector.name,
    depth: stack.len,
  )

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
