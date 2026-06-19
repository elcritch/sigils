## examples/smalltalk/smalltalk.nim
##
## A minimal Smalltalk-like language built on top of sigils DynamicAgent selectors.
##
## Grammar (small subset):
##   program      := statement (' .'? statement)*
##   statement    := IDENT ':=' expression | expression
##   expression   := primary { message-send }
##   message-send := IDENT [ ':' expression ]            # unary or one-arg keyword
##   primary      := IDENT | INT | STRING | '(' expression ')' | true | false | nil
##
## All runtime values are `SmalltalkValue` objects, each subclassing `DynamicAgent`.

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
    tkAssign,
    tkLParen,
    tkRParen,
    tkColon,
    tkDot

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

proc token(kind: TokenKind, value = ""): SmalltalkToken =
  SmalltalkToken(kind: kind, value: value)

proc lexSource*(source: string): seq[SmalltalkToken] =
  var idx = 0
  while idx < source.len:
    if source[idx].isSpaceAscii:
      inc idx
      continue
    if source[idx] == '#':
      inc idx
      while idx < source.len and source[idx] != '\n':
        inc idx
      continue
    if idx + 1 < source.len and source[idx] == ':' and source[idx + 1] == '=':
      result.add token(tkAssign)
      idx += 2
    elif source[idx] == '.':
      result.add token(tkDot)
      inc idx
    elif source[idx] == '(':
      result.add token(tkLParen)
      inc idx
    elif source[idx] == ')':
      result.add token(tkRParen)
      inc idx
    elif source[idx] == ':':
      result.add token(tkColon)
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
      while idx < source.len and (source[idx].isAlphaNumeric or source[idx] == '_'):
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

proc peekNext(state: ParserState): SmalltalkToken =
  if state.pos + 1 < state.tokens.len: state.tokens[state.pos + 1] else: token(tkEof)

proc consume(state: var ParserState): SmalltalkToken =
  if state.isAtEnd:
    return token(tkEof)
  result = state.tokens[state.pos]
  inc state.pos

proc expect*(state: var ParserState, expected: TokenKind) =
  let value = state.consume()
  if value.kind != expected:
    raise newException(SmalltalkError,
      "unexpected token " & $value.kind & ", expected " & $expected)

proc expectIdent(state: var ParserState): string =
  let current = state.consume()
  if current.kind != tkIdent:
    raise newException(SmalltalkError, "expected identifier")
  current.value

proc parseExpr(state: var ParserState): SmalltalkExprRef

proc parsePrimary(state: var ParserState): SmalltalkExprRef =
  if state.isAtEnd:
    raise newException(SmalltalkError, "unexpected end of input")

  let current = state.consume()
  case current.kind
  of tkInt:
    var value = 0
    let consumed = parseutils.parseInt(current.value, value)
    if consumed == 0:
      raise newException(SmalltalkError, "invalid integer literal")
    result = SmalltalkExprRef(kind: exInt, intValue: value)
  of tkString:
    result = SmalltalkExprRef(kind: exString, stringValue: current.value)
  of tkIdent:
    if current.value == "true":
      result = SmalltalkExprRef(kind: exBool, boolValue: true)
    elif current.value == "false":
      result = SmalltalkExprRef(kind: exBool, boolValue: false)
    elif current.value == "nil":
      result = SmalltalkExprRef(kind: exNil)
    else:
      result = SmalltalkExprRef(kind: exVar, varName: current.value)
  of tkLParen:
    result = parseExpr(state)
    state.expect(tkRParen)
  else:
    raise newException(SmalltalkError, "unexpected token in expression: " & $current.kind)

proc parseMessageExpr(state: var ParserState): SmalltalkExprRef =
  var value = parsePrimary(state)
  while state.peek().kind == tkIdent:
    let selector = state.consume().value
    if state.peek().kind == tkColon:
      discard state.consume()
      let arg = parseExpr(state)
      value = SmalltalkExprRef(
        kind: exMessage,
        receiver: value,
        selector: selector & ":",
        args: @[arg]
      )
    else:
      value = SmalltalkExprRef(
        kind: exMessage,
        receiver: value,
        selector: selector,
        args: @[]
      )
  result = value

proc parseExpr(state: var ParserState): SmalltalkExprRef =
  parseMessageExpr(state)

proc parseStatement(state: var ParserState): SmalltalkStmt =
  if state.peek().kind == tkIdent and state.peekNext().kind == tkAssign:
    let name = state.expectIdent()
    state.expect(tkAssign)
    result = SmalltalkStmt(
      kind: stAssign,
      name: name,
      expr: parseExpr(state),
    )
  else:
    result = SmalltalkStmt(
      kind: stExpr,
      expr: parseExpr(state),
    )

proc parseProgram*(source: string): SmalltalkProgram =
  var state = initParser(source)
  while not state.isAtEnd:
    if state.peek().kind == tkDot:
      discard state.consume()
      continue
    let statement = parseStatement(state)
    result.add(statement)
    if state.peek().kind == tkDot:
      discard state.consume()
  if not state.isAtEnd:
    raise newException(SmalltalkError,
      "did not reach end of token stream")

proc newRuntime*: SmalltalkRuntime =
  SmalltalkRuntime(vars: initTable[string, SmalltalkValue]())

proc resolveVar(state: var SmalltalkRuntime, name: string): SmalltalkValue =
  if name in state.vars:
    result = state.vars[name]
  else:
    raise newException(SmalltalkError, "unknown variable: " & name)

proc getVar*(state: SmalltalkRuntime, name: string): SmalltalkValue =
  if name in state.vars:
    state.vars[name]
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
