import std/[macros, options, tables]

import agents

export agents
export options

type
  Selector*[A, R] = object
    ## A typed runtime method name.
    name*: SigilName

  Invocation* = object
    ## Runtime call context passed through dynamic selector dispatch.
    selector*: SigilName
    params*: SigilParams
    result*: SigilParams
    handled*: bool

  DynamicAgent* = ref object of Agent
    methods: Table[SigilName, seq[DynamicMethod]]
    nextResponder: WeakRef[DynamicAgent]

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

proc selectorIdentName(node: NimNode): string =
  if node.kind == nnkPostfix and node.len == 2 and node[0].eqIdent("*"):
    result = node[1].strVal
  else:
    result = node.strVal

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
      argsType = selectorArgsType(params, 1)

    result = quote do:
      template `selectorProc`(): untyped =
        initSelector[`argsType`, `retType`](`selectorName`)
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

    result = newStmtList()
    result.add implDef
    result.add quote do:
      proc `dynProc`(`dynSelf`: DynamicAgent, `invocation`: var Invocation) =
        if `dynSelf` == nil:
          raise newException(ValueError, "bad value")
        let `receiverName` = `receiverType`(`dynSelf`)
        if `receiverName` == nil:
          raise newException(ConversionError, "bad cast")
        when `argsType` is tuple[]:
          `invocation`.setResult(`implProc`(`receiverName`))
        else:
          var `argsIdent`: `argsType`
          rpcUnpack(`argsIdent`, `invocation`.params)
          `invocation`.setResult(`call`)

template selector*(p: untyped): untyped =
  selectorImpl(p)

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

proc replaceMethod*[A, R](
    obj: DynamicAgent,
    selector: Selector[A, R],
    fn: DynamicMethod,
): DynamicMethod {.discardable.} =
  ## Replace the local implementation and return the previous top method, if any.
  result = obj.localMethod(selector.name)
  obj.methods[selector.name] = @[fn]

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
