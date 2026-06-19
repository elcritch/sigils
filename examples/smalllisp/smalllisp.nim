## examples/smalllisp/smalllisp.nim
##
## A tiny Lisp-style Smalltalk-like language implemented with sigils
## DynamicAgent selectors.
##
## Grammar (small subset):
##   program  := statement*
##   stmt     := '( set ident expr ')' | '(' selector expr+ ')'
##   expr     := INT | STRING | true | false | nil | IDENT | list
##
## Message calls are represented as list expressions.
##   (selector receiver arg1 arg2 ...)
## where:
##   - one arg means unary selector (no trailing colon)
##   - one or more additional args means keyword selector (trailing colon)
##   - `set` is reserved for assignment statements.

import std/[parseutils, strutils, tables]

import sigils/selectors

type
  SmalltalkKind* = enum
    stNil,
    stNumber,
    stString,
    stBool

  SmalltalkValue* = ref object of DynamicAgent
    installed*: bool
    kind*: SmalltalkKind
    numberValue*: int
    boolValue*: bool
    stringValue*: string

  SmalltalkError* = object of CatchableError

  TokenKind* = enum
    tkEof,
    tkIdent,
    tkInt,
    tkString,
    tkLParen,
    tkRParen

  SmalltalkToken* = object
    kind*: TokenKind
    value*: string

  ParserState = object
    tokens*: seq[SmalltalkToken]
    pos*: int

  SmalltalkExprKind* = enum
    exInt,
    exString,
    exBool,
    exNil,
    exVar,
    exMessage

  SmalltalkExprRef* = ref SmalltalkExpr

  SmalltalkExpr* = object
    kind*: SmalltalkExprKind
    intValue*: int
    stringValue*: string
    boolValue*: bool
    varName*: string
    receiver*: SmalltalkExprRef
    selector*: string
    args*: seq[SmalltalkExprRef]

  SmalltalkStmtKind* = enum
    stAssign,
    stExpr

  SmalltalkStmt* = object
    kind*: SmalltalkStmtKind
    name*: string
    expr*: SmalltalkExprRef

  SmalltalkProgram* = seq[SmalltalkStmt]

  SmalltalkRuntime* = object
    vars*: Table[string, SmalltalkValue]

  SmalltalkResult* = object
    runtime*: SmalltalkRuntime
    lastValue*: SmalltalkValue

  SmalltalkMessageProc = proc(
    self: SmalltalkValue, args: seq[SmalltalkValue]
  ): SmalltalkValue {.nimcall.}

proc newSmalltalkNumber*(value: int): SmalltalkValue
proc newSmalltalkBool*(value: bool): SmalltalkValue
proc newSmalltalkString*(value: string): SmalltalkValue
proc newSmalltalkNil*: SmalltalkValue
proc bindCoreMethods*(self: SmalltalkValue)

proc argumentCountText(expected: int): string =
  if expected == 0:
    "no arguments"
  elif expected == 1:
    "one argument"
  else:
    $expected & " arguments"

proc expectArgCount(selector: string, args: openArray[SmalltalkValue],
    expected: int) =
  if args.len != expected:
    raise newException(SmalltalkError,
      selector & " expects " & argumentCountText(expected))

proc expectOneArg(selector: string,
    args: openArray[SmalltalkValue]): SmalltalkValue =
  expectArgCount(selector, args, 1)
  result = args[0]

proc stAdd(self: SmalltalkValue, args: seq[SmalltalkValue]): SmalltalkValue =
  let rhs = expectOneArg("add", args)
  case self.kind
  of stNumber:
    if rhs.kind != stNumber:
      raise newException(SmalltalkError,
        "add requires matching number or string operands")
    result = newSmalltalkNumber(self.numberValue + rhs.numberValue)
  of stString:
    if rhs.kind != stString:
      raise newException(SmalltalkError,
        "add requires matching number or string operands")
    result = newSmalltalkString(self.stringValue & rhs.stringValue)
  else:
    raise newException(SmalltalkError,
      "add requires matching number or string operands")

proc stSub(self: SmalltalkValue, args: seq[SmalltalkValue]): SmalltalkValue =
  let rhs = expectOneArg("sub", args)
  if self.kind != stNumber or rhs.kind != stNumber:
    raise newException(SmalltalkError,
      "sub requires number receiver and number argument")
  result = newSmalltalkNumber(self.numberValue - rhs.numberValue)

proc stMul(self: SmalltalkValue, args: seq[SmalltalkValue]): SmalltalkValue =
  let rhs = expectOneArg("mul", args)
  if self.kind != stNumber or rhs.kind != stNumber:
    raise newException(SmalltalkError,
      "mul requires number receiver and number argument")
  result = newSmalltalkNumber(self.numberValue * rhs.numberValue)

proc stDiv(self: SmalltalkValue, args: seq[SmalltalkValue]): SmalltalkValue =
  let rhs = expectOneArg("div", args)
  if self.kind != stNumber or rhs.kind != stNumber:
    raise newException(SmalltalkError,
      "div requires number receiver and number argument")
  if rhs.numberValue == 0:
    raise newException(SmalltalkError, "division by zero")
  result = newSmalltalkNumber(self.numberValue div rhs.numberValue)

proc stLt(self: SmalltalkValue, args: seq[SmalltalkValue]): SmalltalkValue =
  let rhs = expectOneArg("lt", args)
  if self.kind != stNumber or rhs.kind != stNumber:
    raise newException(SmalltalkError,
      "lt requires number receiver and number argument")
  result = newSmalltalkBool(self.numberValue < rhs.numberValue)

proc stEq(self: SmalltalkValue, args: seq[SmalltalkValue]): SmalltalkValue =
  let rhs = expectOneArg("eq", args)
  case self.kind
  of stNumber:
    if rhs.kind != stNumber:
      result = newSmalltalkBool(false)
    else:
      result = newSmalltalkBool(self.numberValue == rhs.numberValue)
  of stString:
    if rhs.kind != stString:
      result = newSmalltalkBool(false)
    else:
      result = newSmalltalkBool(self.stringValue == rhs.stringValue)
  of stBool:
    if rhs.kind != stBool:
      result = newSmalltalkBool(false)
    else:
      result = newSmalltalkBool(self.boolValue == rhs.boolValue)
  of stNil:
    result = newSmalltalkBool(rhs.kind == stNil)

proc stAsString(self: SmalltalkValue,
    args: seq[SmalltalkValue]): SmalltalkValue =
  expectArgCount("asString", args, 0)
  case self.kind
  of stNumber:
    result = newSmalltalkString($self.numberValue)
  of stBool:
    result = newSmalltalkString($self.boolValue)
  of stString:
    result = newSmalltalkString(self.stringValue)
  of stNil:
    result = newSmalltalkString("nil")

proc stPrint(self: SmalltalkValue, args: seq[SmalltalkValue]): SmalltalkValue =
  expectArgCount("print", args, 0)
  echo stAsString(self, @[]).stringValue
  result = self

proc smalltalkSelector(
    name: static string
): Selector[seq[SmalltalkValue], SmalltalkValue] =
  selector[seq[SmalltalkValue], SmalltalkValue](name)

proc bindSmalltalkMethod(
    self: SmalltalkValue, name: static string, fn: SmalltalkMessageProc
) =
  discard self.addMethod(smalltalkSelector(name), toDynamicMethod(fn))

proc newSmalltalkNumber*(value: int): SmalltalkValue =
  result = SmalltalkValue(kind: stNumber, numberValue: value)
  result.bindCoreMethods()

proc newSmalltalkBool*(value: bool): SmalltalkValue =
  result = SmalltalkValue(kind: stBool, boolValue: value)
  result.bindCoreMethods()

proc newSmalltalkString*(value: string): SmalltalkValue =
  result = SmalltalkValue(kind: stString, stringValue: value)
  result.bindCoreMethods()

proc newSmalltalkNil*: SmalltalkValue =
  result = SmalltalkValue(kind: stNil)
  result.bindCoreMethods()

proc bindCoreMethods*(self: SmalltalkValue) =
  if self.installed:
    return
  self.installed = true
  self.bindSmalltalkMethod("add:", stAdd)
  self.bindSmalltalkMethod("add", stAdd)
  self.bindSmalltalkMethod("sub:", stSub)
  self.bindSmalltalkMethod("sub", stSub)
  self.bindSmalltalkMethod("mul:", stMul)
  self.bindSmalltalkMethod("mul", stMul)
  self.bindSmalltalkMethod("div:", stDiv)
  self.bindSmalltalkMethod("div", stDiv)
  self.bindSmalltalkMethod("lt:", stLt)
  self.bindSmalltalkMethod("lt", stLt)
  self.bindSmalltalkMethod("eq:", stEq)
  self.bindSmalltalkMethod("eq", stEq)
  self.bindSmalltalkMethod("asString", stAsString)
  self.bindSmalltalkMethod("print", stPrint)

proc toInt*(self: SmalltalkValue): int =
  if self.kind != stNumber:
    raise newException(SmalltalkError, "expected number")
  self.numberValue

proc toBool*(self: SmalltalkValue): bool =
  if self.kind != stBool:
    raise newException(SmalltalkError, "expected bool")
  self.boolValue

proc toString*(self: SmalltalkValue): string =
  if self.kind != stString:
    raise newException(SmalltalkError, "expected string")
  self.stringValue

proc getVar*(state: SmalltalkRuntime, name: string): SmalltalkValue =
  if name in state.vars:
    state.vars[name]
  else:
    raise newException(SmalltalkError, "unknown variable: " & name)

proc token(kind: TokenKind, value = ""): SmalltalkToken =
  SmalltalkToken(kind: kind, value: value)

proc lexSource*(source: string): seq[SmalltalkToken] =
  var idx = 0
  while idx < source.len:
    if source[idx].isSpaceAscii:
      inc idx
      continue
    if source[idx] == ';':
      inc idx
      while idx < source.len and source[idx] != '\n':
        inc idx
      continue
    if source[idx] == '(':
      result.add token(tkLParen)
      inc idx
    elif source[idx] == ')':
      result.add token(tkRParen)
      inc idx
    elif source[idx] == '"':
      inc idx
      var literal = ""
      while idx < source.len and source[idx] != '"':
        if source[idx] == '\\' and idx + 1 < source.len:
          inc idx
          case source[idx]
          of 'n':
            literal.add('\n')
          of 't':
            literal.add('\t')
          of '"':
            literal.add('"')
          of '\\':
            literal.add('\\')
          else:
            literal.add(source[idx])
        else:
          literal.add(source[idx])
        inc idx
      if idx >= source.len:
        raise newException(SmalltalkError, "unterminated string literal")
      inc idx
      result.add token(tkString, literal)
    elif source[idx] in {'0'..'9'}:
      var value = 0
      let used = parseutils.parseInt(source, value, idx)
      if used == 0:
        raise newException(SmalltalkError,
          "invalid integer literal at index " & $idx)
      idx += used
      result.add token(tkInt, $value)
    elif source[idx].isAlphaAscii or source[idx] == '_':
      let start = idx
      inc idx
      while idx < source.len and
          (source[idx].isAlphaNumeric or source[idx] == '_' or source[idx] == '-'):
        inc idx
      result.add token(tkIdent, source[start..<idx])
    else:
      raise newException(SmalltalkError,
        "unexpected character: " & source[idx])
  result.add token(tkEof)

proc initParser*(source: string): ParserState =
  ParserState(tokens: lexSource(source), pos: 0)

proc isAtEnd(state: ParserState): bool =
  state.pos >= state.tokens.len or state.tokens[state.pos].kind == tkEof

proc peek*(state: ParserState): SmalltalkToken =
  if state.pos < state.tokens.len: state.tokens[state.pos] else: token(tkEof)

proc consume(state: var ParserState): SmalltalkToken =
  if state.isAtEnd:
    return token(tkEof)
  result = state.tokens[state.pos]
  inc state.pos

proc expect*(state: var ParserState, expected: TokenKind) =
  let current = state.consume()
  if current.kind != expected:
    raise newException(SmalltalkError,
      "unexpected token " & $current.kind & ", expected " & $expected)

proc expectIdent(state: var ParserState): string =
  let current = state.consume()
  if current.kind != tkIdent:
    raise newException(SmalltalkError, "expected identifier")
  current.value

proc parseExpr(state: var ParserState): SmalltalkExprRef

proc parseListExpr(state: var ParserState, selector: string): SmalltalkExprRef =
  let receiver = parseExpr(state)
  var args: seq[SmalltalkExprRef] = @[]
  while not state.isAtEnd and state.peek().kind != tkRParen:
    args.add state.parseExpr()
  state.expect(tkRParen)
  let messageSelector =
    if args.len > 0: selector & ":" else: selector
  SmalltalkExprRef(
    kind: exMessage,
    receiver: receiver,
    selector: messageSelector,
    args: args
  )

proc parseExpr(state: var ParserState): SmalltalkExprRef =
  let current = state.peek()
  if current.kind == tkLParen:
    discard state.consume() # consume '('
    let selectorToken = state.consume()
    if selectorToken.kind != tkIdent:
      raise newException(SmalltalkError, "expected selector")
    if selectorToken.value == "set":
      raise newException(SmalltalkError, "set is only valid as top-level statement")
    parseListExpr(state, selectorToken.value)
  else:
    discard state.consume()
    case current.kind
    of tkInt:
      var value = 0
      let consumed = parseutils.parseInt(current.value, value)
      if consumed == 0:
        raise newException(SmalltalkError, "invalid integer literal")
      SmalltalkExprRef(kind: exInt, intValue: value)
    of tkString:
      SmalltalkExprRef(kind: exString, stringValue: current.value)
    of tkIdent:
      if current.value == "true":
        SmalltalkExprRef(kind: exBool, boolValue: true)
      elif current.value == "false":
        SmalltalkExprRef(kind: exBool, boolValue: false)
      elif current.value == "nil":
        SmalltalkExprRef(kind: exNil)
      else:
        SmalltalkExprRef(kind: exVar, varName: current.value)
    else:
      raise newException(SmalltalkError,
        "unexpected token in expression: " & $current.kind)

proc parseStatement(state: var ParserState): SmalltalkStmt =
  if state.peek().kind != tkLParen:
    let expr = state.parseExpr()
    return SmalltalkStmt(kind: stExpr, expr: expr)

  discard state.consume() # consume '('
  let selectorToken = state.consume()
  if selectorToken.kind != tkIdent:
    raise newException(SmalltalkError, "expected identifier")

  if selectorToken.value == "set":
    if state.peek().kind != tkIdent:
      raise newException(SmalltalkError, "expected variable name")
    let name = state.expectIdent()
    let value = state.parseExpr()
    state.expect(tkRParen)
    return SmalltalkStmt(kind: stAssign, name: name, expr: value)

  if state.peek().kind == tkRParen:
    raise newException(SmalltalkError, "message call requires a receiver")

  let receiver = state.parseExpr()
  var args: seq[SmalltalkExprRef] = @[]
  while state.peek().kind != tkRParen:
    args.add state.parseExpr()
  state.expect(tkRParen)

  let selector =
    if args.len > 0: selectorToken.value & ":" else: selectorToken.value
  let expr = SmalltalkExprRef(
    kind: exMessage,
    receiver: receiver,
    selector: selector,
    args: args
  )
  SmalltalkStmt(kind: stExpr, expr: expr)

proc parseProgram*(source: string): SmalltalkProgram =
  var state = initParser(source)
  while not state.isAtEnd:
    result.add state.parseStatement()

proc newRuntime*: SmalltalkRuntime =
  SmalltalkRuntime(vars: initTable[string, SmalltalkValue]())

proc resolveVar(state: var SmalltalkRuntime, name: string): SmalltalkValue =
  if name in state.vars:
    result = state.vars[name]
  else:
    raise newException(SmalltalkError, "unknown variable: " & name)

proc sendByName(
    receiver: SmalltalkValue,
    selector: string,
    args: openArray[SmalltalkValue]
): SmalltalkValue =
  receiver.bindCoreMethods()

  var messageArgs = newSeq[SmalltalkValue](args.len)
  for idx, arg in args:
    messageArgs[idx] = arg

  var invocation = initInvocation(selector.toSigilName(), messageArgs)
  if receiver.dispatch(invocation):
    result = invocation.resultAs(SmalltalkValue)
  else:
    raise newException(SmalltalkError, "unknown selector: " & selector)

proc evalExpr*(state: var SmalltalkRuntime,
    expr: SmalltalkExprRef): SmalltalkValue =
  case expr.kind
  of exInt:
    result = newSmalltalkNumber(expr.intValue)
  of exString:
    result = newSmalltalkString(expr.stringValue)
  of exBool:
    result = newSmalltalkBool(expr.boolValue)
  of exNil:
    result = newSmalltalkNil()
  of exVar:
    result = state.resolveVar(expr.varName)
  of exMessage:
    let receiver = state.evalExpr(expr.receiver)
    var argValues: seq[SmalltalkValue] = @[]
    for item in expr.args:
      argValues.add state.evalExpr(item)
    result = sendByName(receiver, expr.selector, argValues)

proc execute*(
  runtime: var SmalltalkRuntime,
  statement: SmalltalkStmt
): SmalltalkValue =
  case statement.kind
  of stAssign:
    let value = runtime.evalExpr(statement.expr)
    runtime.vars[statement.name] = value
    result = value
  of stExpr:
    result = runtime.evalExpr(statement.expr)

proc run*(runtime: var SmalltalkRuntime,
    program: SmalltalkProgram): SmalltalkValue =
  for statement in program:
    result = runtime.execute(statement)

proc runSource*(source: string): SmalltalkResult =
  var runtime = newRuntime()
  let program = parseProgram(source)
  let last = run(runtime, program)
  SmalltalkResult(runtime: runtime, lastValue: last)
