import std/[macros, options, strutils]

import agents
import selectorMethodStores
import signals
import slots

export agents
export options
export signals

type
  Selector*[A, R] = object
    ## A typed runtime method name.
    name*: SigilName

  ProtocolRequirement* = object
    ## A selector requirement declared by a dynamic protocol.
    selector*: SigilName
    signature*: string
    required*: bool

  ProtocolSignal* = object
    ## A signal declared as part of a dynamic protocol's descriptive surface.
    name*: SigilName
    signature*: string

  ProtocolSlot* = object
    ## A slot declared as part of a dynamic protocol's descriptive surface.
    name*: SigilName
    eventName*: SigilName
    signature*: string

  SelectorMethod* = object
    ## A selector paired with a dynamic implementation for batch installs.
    selector*: SigilName
    implementation*: DynamicMethod

  ProtocolObserverProc* = proc(
    source: Agent, observer: Agent
  ) {.nimcall.}

  ProtocolObserverBinding* = object
    ## Runtime connector for protocol event observation installed on an object.
    protocol*: SigilName
    implementation*: SigilName
    connect*: ProtocolObserverProc
    disconnect*: ProtocolObserverProc

  SigilProtocol* = object
    ## A named runtime contract made of selector requirements, signals, and slots.
    name*: SigilName
    requirements*: seq[ProtocolRequirement]
    signals*: seq[ProtocolSignal]
    slots*: seq[ProtocolSlot]

  ProtocolImplementation* = object
    ## A protocol paired with dynamic methods implementing its selectors.
    protocol*: SigilProtocol
    methods*: seq[SelectorMethod]
    observers*: seq[ProtocolObserverBinding]

  SelectorDefaultArg = object

  ProtocolPropertyNilPolicy = enum
    propertyNilUnchecked
    propertyNilSafe
    propertyNilCheck

  ProtocolProperty = object
    name: NimNode
    valueType: NimNode
    field: NimNode
    nilPolicy: ProtocolPropertyNilPolicy

  SelectorScope = enum
    selectorScopeNone
    selectorScopeProtocol

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
    argsPtr: pointer
    resultPtr: pointer
    resultWritten: bool

  ForwardingTarget* = proc(
    self: DynamicAgent, selector: SigilName
  ): DynamicAgent {.closure.}

  ForwardInvocation* = proc(
    self: DynamicAgent, invocation: var Invocation
  ): bool {.closure.}

  ResolveMethod* = proc(
    self: DynamicAgent, selector: SigilName
  ): bool {.closure.}

  DispatchFrame = object
    selector: SigilName
    index: int

  DynamicAgent* = ref object of Agent
    methods: SelectorMethodStore[DynamicMethod]
    dispatchFrames: seq[DispatchFrame]
    nextResponder: WeakRef[DynamicAgent]
    adoptedProtocols: seq[SigilName]
    protocolObservers: seq[ProtocolObserverBinding]
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

when sigilsSigilNameStringEnabled:
  proc protocolSignal*(name: string, signature = ""): ProtocolSignal =
    result = ProtocolSignal(
      name: toSigilName(name),
      signature: signature,
    )

  proc protocolSlot*(
      name: static string, signature = "", eventName: static string = ""
  ): ProtocolSlot =
    let resolvedEventName =
      if eventName.len == 0:
        name
      else:
        eventName
    result = ProtocolSlot(
      name: toSigilName(name),
      eventName: toSigilName(resolvedEventName),
      signature: signature,
    )

  proc protocolSlot*(
      name: string, signature = "", eventName: string = ""
  ): ProtocolSlot =
    let resolvedEventName =
      if eventName.len == 0:
        name
      else:
        eventName
    result = ProtocolSlot(
      name: toSigilName(name),
      eventName: toSigilName(resolvedEventName),
      signature: signature,
    )

else:
  proc protocolSignal*(name: SigilName, signature = ""): ProtocolSignal =
    result = ProtocolSignal(
      name: name,
      signature: signature,
    )

  proc protocolSignal*(name: static string, signature = ""): ProtocolSignal =
    protocolSignal(toSigilName(name), signature)

  proc protocolSignal*(name: string, signature = ""): ProtocolSignal =
    protocolSignal(toSigilName(name), signature)

  proc protocolSlot*(
      name: SigilName,
      signature = "",
      eventName: SigilName = default(SigilName),
  ): ProtocolSlot =
    let resolvedEventName =
      if eventName == default(SigilName):
        name
      else:
        eventName
    result = ProtocolSlot(
      name: name,
      eventName: resolvedEventName,
      signature: signature,
    )

  proc protocolSlot*(
      name: static string, signature = "", eventName: static string = ""
  ): ProtocolSlot =
    protocolSlot(
      toSigilName(name),
      signature,
      if eventName.len == 0: toSigilName(name) else: toSigilName(eventName),
    )

  proc protocolSlot*(
      name: string, signature = "", eventName: string = ""
  ): ProtocolSlot =
    protocolSlot(
      toSigilName(name),
      signature,
      if eventName.len == 0: toSigilName(name) else: toSigilName(eventName),
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

proc initProtocol*(
    name: static string,
    requirements: openArray[ProtocolRequirement],
    signals: openArray[ProtocolSignal],
): SigilProtocol =
  result = SigilProtocol(
    name: toSigilName(name),
    requirements: @requirements,
    signals: @signals,
  )

proc initProtocol*(
    name: string,
    requirements: openArray[ProtocolRequirement],
    signals: openArray[ProtocolSignal],
): SigilProtocol =
  result = SigilProtocol(
    name: toSigilName(name),
    requirements: @requirements,
    signals: @signals,
  )

proc initProtocol*(
    name: static string,
    requirements: openArray[ProtocolRequirement],
    signals: openArray[ProtocolSignal],
    slots: openArray[ProtocolSlot],
): SigilProtocol =
  result = SigilProtocol(
    name: toSigilName(name),
    requirements: @requirements,
    signals: @signals,
    slots: @slots,
  )

proc initProtocol*(
    name: string,
    requirements: openArray[ProtocolRequirement],
    signals: openArray[ProtocolSignal],
    slots: openArray[ProtocolSlot],
): SigilProtocol =
  result = SigilProtocol(
    name: toSigilName(name),
    requirements: @requirements,
    signals: @signals,
    slots: @slots,
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

proc containsProtocolSignal(
    signals: openArray[ProtocolSignal], name: SigilName
): bool =
  for signal in signals:
    if signal.name == name:
      return true

proc composeProtocolSignals*(
    protocols: openArray[SigilProtocol],
    signals: openArray[ProtocolSignal],
): seq[ProtocolSignal] =
  ## Merge inherited and local protocol signals, keeping the first occurrence.
  for protocol in protocols:
    for signal in protocol.signals:
      if not result.containsProtocolSignal(signal.name):
        result.add signal
  for signal in signals:
    if not result.containsProtocolSignal(signal.name):
      result.add signal

proc containsProtocolSlot(
    slots: openArray[ProtocolSlot], name: SigilName
): bool =
  for slot in slots:
    if slot.name == name:
      return true

proc composeProtocolSlots*(
    protocols: openArray[SigilProtocol],
    slots: openArray[ProtocolSlot],
): seq[ProtocolSlot] =
  ## Merge inherited and local protocol slots, keeping the first occurrence.
  for protocol in protocols:
    for slot in protocol.slots:
      if not result.containsProtocolSlot(slot.name):
        result.add slot
  for slot in slots:
    if not result.containsProtocolSlot(slot.name):
      result.add slot

proc initProtocol*(
    name: static string,
    protocols: openArray[SigilProtocol],
    requirements: openArray[ProtocolRequirement],
): SigilProtocol =
  result = SigilProtocol(
    name: toSigilName(name),
    requirements: composeRequirements(protocols, requirements),
    signals: composeProtocolSignals(protocols, []),
    slots: composeProtocolSlots(protocols, []),
  )

proc initProtocol*(
    name: string,
    protocols: openArray[SigilProtocol],
    requirements: openArray[ProtocolRequirement],
): SigilProtocol =
  result = SigilProtocol(
    name: toSigilName(name),
    requirements: composeRequirements(protocols, requirements),
    signals: composeProtocolSignals(protocols, []),
    slots: composeProtocolSlots(protocols, []),
  )

proc initProtocol*(
    name: static string,
    protocols: openArray[SigilProtocol],
    requirements: openArray[ProtocolRequirement],
    signals: openArray[ProtocolSignal],
): SigilProtocol =
  result = SigilProtocol(
    name: toSigilName(name),
    requirements: composeRequirements(protocols, requirements),
    signals: composeProtocolSignals(protocols, signals),
    slots: composeProtocolSlots(protocols, []),
  )

proc initProtocol*(
    name: string,
    protocols: openArray[SigilProtocol],
    requirements: openArray[ProtocolRequirement],
    signals: openArray[ProtocolSignal],
): SigilProtocol =
  result = SigilProtocol(
    name: toSigilName(name),
    requirements: composeRequirements(protocols, requirements),
    signals: composeProtocolSignals(protocols, signals),
    slots: composeProtocolSlots(protocols, []),
  )

proc initProtocol*(
    name: static string,
    protocols: openArray[SigilProtocol],
    requirements: openArray[ProtocolRequirement],
    signals: openArray[ProtocolSignal],
    slots: openArray[ProtocolSlot],
): SigilProtocol =
  result = SigilProtocol(
    name: toSigilName(name),
    requirements: composeRequirements(protocols, requirements),
    signals: composeProtocolSignals(protocols, signals),
    slots: composeProtocolSlots(protocols, slots),
  )

proc initProtocol*(
    name: string,
    protocols: openArray[SigilProtocol],
    requirements: openArray[ProtocolRequirement],
    signals: openArray[ProtocolSignal],
    slots: openArray[ProtocolSlot],
): SigilProtocol =
  result = SigilProtocol(
    name: toSigilName(name),
    requirements: composeRequirements(protocols, requirements),
    signals: composeProtocolSignals(protocols, signals),
    slots: composeProtocolSlots(protocols, slots),
  )

proc initProtocolImplementation*(
    protocol: SigilProtocol, methods: openArray[SelectorMethod]
): ProtocolImplementation =
  result = ProtocolImplementation(
    protocol: protocol,
    methods: @methods,
  )

proc initProtocolImplementation*(
    protocol: SigilProtocol,
    methods: openArray[SelectorMethod],
    observers: openArray[ProtocolObserverBinding],
): ProtocolImplementation =
  result = ProtocolImplementation(
    protocol: protocol,
    methods: @methods,
    observers: @observers,
  )

proc protocolObserver*(
    protocol: SigilProtocol,
    implementation: SigilProtocol,
    connect: ProtocolObserverProc,
    disconnect: ProtocolObserverProc,
): ProtocolObserverBinding =
  result = ProtocolObserverBinding(
    protocol: protocol.name,
    implementation: implementation.name,
    connect: connect,
    disconnect: disconnect,
  )

proc protocolObserver*(
    protocol: SigilProtocol,
    implementation: static string,
    connect: ProtocolObserverProc,
    disconnect: ProtocolObserverProc,
): ProtocolObserverBinding =
  result = ProtocolObserverBinding(
    protocol: protocol.name,
    implementation: toSigilName(implementation),
    connect: connect,
    disconnect: disconnect,
  )

template selectorDefaultArg(): SelectorDefaultArg =
  SelectorDefaultArg()

proc selectorIdentName(node: NimNode): string =
  if node.kind == nnkPostfix and node.len == 2 and node[0].eqIdent("*"):
    result = selectorIdentName(node[1])
  elif node.kind == nnkAccQuoted:
    for part in node:
      result.add selectorIdentName(part)
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

proc checkSigilNameLength(name: string, node: NimNode, kind: string) =
  when not sigilsSigilNameStringEnabled:
    if name.len > sigilsMaxSignalLength:
      error(
        kind & " `" & name & "` is " & $name.len &
          " bytes, but SigilName capacity is " & $sigilsMaxSignalLength,
        node,
      )

proc scopedSelectorName(
    protocolName: string, selectorName: string, selectorScope: SelectorScope
): string =
  case selectorScope
  of selectorScopeNone:
    selectorName
  of selectorScopeProtocol:
    protocolName & "." & selectorName

proc unwrappedPar(node: NimNode): NimNode =
  if node.kind == nnkPar and node.len == 1:
    node[0]
  else:
    node

proc protocolNameAndScope(name: NimNode): tuple[name: NimNode,
    selectorScope: SelectorScope] =
  result.name = name.unwrappedPar.copyNimTree()
  result.selectorScope = selectorScopeNone

  let node = name.unwrappedPar
  if node.kind != nnkPragmaExpr:
    return

  result.name = node[0].unwrappedPar.copyNimTree()
  for pragma in node[1]:
    if pragma.kind == nnkExprColonExpr and pragma.len == 2 and
        pragma[0].eqIdent("selectorScope"):
      if pragma[1].eqIdent("protocol"):
        result.selectorScope = selectorScopeProtocol
      elif pragma[1].eqIdent("none"):
        result.selectorScope = selectorScopeNone
      else:
        error("selectorScope must be `protocol` or `none`", pragma[1])
    else:
      error("unsupported protocol pragma", pragma)

proc protocolSlotCheckIdent(name: NimNode): NimNode =
  selectorIdent(
    "check" & selectorIdentName(name) & "Slots",
    true,
  )

proc protocolSlotCheckCall(protocol: NimNode, receiver: NimNode): NimNode =
  if protocol.kind == nnkDotExpr and protocol.len == 2:
    result = newCall(
      nnkDotExpr.newTree(
        protocol[0].copyNimTree(),
        ident("check" & selectorIdentName(protocol[1]) & "Slots"),
      ),
      receiver.copyNimTree(),
    )
  else:
    result = newCall(
      ident("check" & selectorIdentName(protocol) & "Slots"),
      receiver.copyNimTree(),
    )

proc protocolConnectIdent(name: NimNode): NimNode =
  selectorIdent(
    "connect" & selectorIdentName(name) & "Protocol",
    true,
  )

proc protocolDisconnectIdent(name: NimNode): NimNode =
  selectorIdent(
    "disconnect" & selectorIdentName(name) & "Protocol",
    true,
  )

proc protocolConnectRuntimeIdent(name: NimNode): NimNode =
  ident("connect" & selectorIdentName(name) & "ProtocolObserver")

proc protocolDisconnectRuntimeIdent(name: NimNode): NimNode =
  ident("disconnect" & selectorIdentName(name) & "ProtocolObserver")

proc protocolHasSignalNameIdent(name: NimNode): NimNode =
  selectorIdent(
    "has" & selectorIdentName(name) & "SignalName",
    true,
  )

proc protocolSignalSlotCheckIdent(name: NimNode): NimNode =
  selectorIdent(
    "check" & selectorIdentName(name) & "SignalSlot",
    true,
  )

proc protocolConnectSlotIdent(name: NimNode): NimNode =
  selectorIdent(
    "connect" & selectorIdentName(name) & "ProtocolSlot",
    true,
  )

proc protocolDisconnectSlotIdent(name: NimNode): NimNode =
  selectorIdent(
    "disconnect" & selectorIdentName(name) & "ProtocolSlot",
    true,
  )

proc protocolObserverCall(
    protocol: NimNode, source: NimNode, observer: NimNode, disconnect = false
): NimNode =
  let callName =
    if disconnect:
      "disconnect" & selectorIdentName(
        if protocol.kind == nnkDotExpr and protocol.len == 2: protocol[
            1] else: protocol
      ) & "Protocol"
    else:
      "connect" & selectorIdentName(
        if protocol.kind == nnkDotExpr and protocol.len == 2: protocol[
            1] else: protocol
      ) & "Protocol"

  if protocol.kind == nnkDotExpr and protocol.len == 2:
    result = newCall(
      nnkDotExpr.newTree(
        protocol[0].copyNimTree(),
        ident(callName),
      ),
      source.copyNimTree(),
      observer.copyNimTree(),
    )
  else:
    result = newCall(
      ident(callName),
      source.copyNimTree(),
      observer.copyNimTree(),
    )

proc protocolHasSignalNameCall(protocol: NimNode,
    signalName: NimNode): NimNode =
  let callName = "has" & selectorIdentName(
    if protocol.kind == nnkDotExpr and protocol.len == 2: protocol[
        1] else: protocol
  ) & "SignalName"

  if protocol.kind == nnkDotExpr and protocol.len == 2:
    result = newCall(
      nnkDotExpr.newTree(protocol[0].copyNimTree(), ident(callName)),
      signalName.copyNimTree(),
    )
  else:
    result = newCall(ident(callName), signalName.copyNimTree())

proc protocolSignalSlotCheckCall(
    protocol: NimNode,
    signalName: NimNode,
    receiver: NimNode,
    slotName: NimNode = nil,
): NimNode =
  let callName = "check" & selectorIdentName(
    if protocol.kind == nnkDotExpr and protocol.len == 2: protocol[
        1] else: protocol
  ) & "SignalSlot"

  if protocol.kind == nnkDotExpr and protocol.len == 2:
    result = newCall(
      nnkDotExpr.newTree(protocol[0].copyNimTree(), ident(callName)),
      signalName.copyNimTree(),
      receiver.copyNimTree(),
      if slotName.isNil: ident(selectorIdentName(
          signalName)) else: slotName.copyNimTree(),
    )
  else:
    result = newCall(
      ident(callName),
      signalName.copyNimTree(),
      receiver.copyNimTree(),
      if slotName.isNil: ident(selectorIdentName(
          signalName)) else: slotName.copyNimTree(),
    )

proc protocolObserverSlotCall(
    protocol: NimNode,
    eventName: NimNode,
    source: NimNode,
    observer: NimNode,
    slot: NimNode,
    disconnect = false,
): NimNode =
  let callName =
    if disconnect:
      "disconnect" & selectorIdentName(
        if protocol.kind == nnkDotExpr and protocol.len == 2: protocol[
            1] else: protocol
      ) & "ProtocolSlot"
    else:
      "connect" & selectorIdentName(
        if protocol.kind == nnkDotExpr and protocol.len == 2: protocol[
            1] else: protocol
      ) & "ProtocolSlot"

  if protocol.kind == nnkDotExpr and protocol.len == 2:
    result = newCall(
      nnkDotExpr.newTree(protocol[0].copyNimTree(), ident(callName)),
      eventName.copyNimTree(),
      source.copyNimTree(),
      observer.copyNimTree(),
      slot.copyNimTree(),
    )
  else:
    result = newCall(
      ident(callName),
      eventName.copyNimTree(),
      source.copyNimTree(),
      observer.copyNimTree(),
      slot.copyNimTree(),
    )

proc setterIdentName(name: string): string =
  if name.len == 0:
    return "set"
  result = "set" & name
  result[3] = result[3].toUpperAscii

proc setPropertyNilPolicy(
    nilPolicy: var ProtocolPropertyNilPolicy,
    value: ProtocolPropertyNilPolicy,
    pragma: NimNode,
) =
  if nilPolicy != propertyNilUnchecked:
    error("property nil policy can only be declared once", pragma)
  nilPolicy = value

proc propertyValueType(
    valueType: NimNode,
    field: var NimNode,
    nilPolicy: var ProtocolPropertyNilPolicy,
): NimNode =
  if valueType.kind != nnkPragmaExpr:
    return valueType.copyNimTree()

  result = valueType[0].copyNimTree()
  for pragma in valueType[1]:
    if pragma.kind == nnkExprColonExpr and pragma.len == 2 and
        pragma[0].eqIdent("field"):
      if not field.isNil:
        error("property field pragma can only be declared once", pragma)
      field = pragma[1].copyNimTree()
    elif pragma.kind == nnkCall and pragma.len == 2 and pragma[0].eqIdent("field"):
      if not field.isNil:
        error("property field pragma can only be declared once", pragma)
      field = pragma[1].copyNimTree()
    elif pragma.kind == nnkIdent and pragma.eqIdent("nilSafe"):
      nilPolicy.setPropertyNilPolicy(propertyNilSafe, pragma)
    elif pragma.kind == nnkIdent and pragma.eqIdent("checkNil"):
      nilPolicy.setPropertyNilPolicy(propertyNilCheck, pragma)
    else:
      error("unsupported property pragma", pragma)

proc protocolProperty(item: NimNode): tuple[prop: ProtocolProperty, found: bool] =
  if item.kind != nnkCommand or item.len < 2 or not item[0].eqIdent("property"):
    return

  if item.len == 2 and item[1].kind == nnkInfix and item[1].len == 3 and
      item[1][0].eqIdent("->"):
    var field: NimNode
    var nilPolicy = propertyNilUnchecked
    let valueType = propertyValueType(item[1][2], field, nilPolicy)
    if field.isNil and nilPolicy != propertyNilUnchecked:
      error("property nil policy requires a field pragma", item)
    result.prop = ProtocolProperty(
      name: item[1][1].copyNimTree(),
      valueType: valueType,
      field: field,
      nilPolicy: nilPolicy,
    )
    result.found = true
    return

  error("property declarations use: property name -> Type", item)

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

proc propertyMethods(prop: ProtocolProperty): seq[NimNode] =
  propertyMethods(prop.name, prop.valueType)

proc propertyFieldExpr(receiver: NimNode, field: NimNode): NimNode =
  if field.kind == nnkDotExpr and field.len == 2:
    return nnkDotExpr.newTree(
      propertyFieldExpr(receiver, field[0]),
      field[1].copyNimTree(),
    )
  nnkDotExpr.newTree(receiver.copyNimTree(), field.copyNimTree())

proc propertyFieldParts(field: NimNode, parts: var seq[NimNode]) =
  if field.kind == nnkDotExpr and field.len == 2:
    propertyFieldParts(field[0], parts)
    parts.add field[1].copyNimTree()
  else:
    parts.add field.copyNimTree()

proc propertyNilCheckPrefixes(receiver: NimNode, field: NimNode): seq[NimNode] =
  result.add receiver.copyNimTree()

  var parts: seq[NimNode]
  propertyFieldParts(field, parts)
  var prefix = receiver.copyNimTree()
  for idx in 0 ..< max(0, parts.len - 1):
    prefix = nnkDotExpr.newTree(prefix, parts[idx].copyNimTree())
    result.add prefix.copyNimTree()

proc propertyNilGuard(
    prefix: NimNode,
    valueType: NimNode,
    nilPolicy: ProtocolPropertyNilPolicy,
    setter: bool,
): NimNode =
  let condition = nnkInfix.newTree(ident"==", prefix.copyNimTree(), newNilLit())
  let action =
    case nilPolicy
    of propertyNilUnchecked:
      newStmtList()
    of propertyNilSafe:
      if setter:
        quote do:
          return
      else:
        quote do:
          return default(`valueType`)
    of propertyNilCheck:
      quote do:
        raise newException(NilAccessDefect, "nil property field")

  result = quote do:
    when compiles(`condition`):
      if `condition`:
        `action`

proc propertyFieldBody(
    prop: ProtocolProperty, receiverName: NimNode, setter = false
): NimNode =
  result = newStmtList()
  if prop.nilPolicy != propertyNilUnchecked:
    for prefix in propertyNilCheckPrefixes(receiverName, prop.field):
      result.add propertyNilGuard(prefix, prop.valueType, prop.nilPolicy, setter)

  let fieldExpr = propertyFieldExpr(receiverName, prop.field)
  if setter:
    result.add newAssignment(fieldExpr, ident"value")
  else:
    result.add fieldExpr

proc propertyImplementationMethods(
    prop: ProtocolProperty, receiverType: NimNode
): seq[NimNode] =
  let
    receiverName = ident("self")
    getter = propertyMethod(prop.name, prop.valueType)
    setter = propertyMethod(prop.name, prop.valueType, setter = true)

  getter[3].insert(
    1,
    newIdentDefs(receiverName.copyNimTree(), receiverType.copyNimTree()),
  )
  getter[6] = propertyFieldBody(prop, receiverName)

  setter[3].insert(
    1,
    newIdentDefs(receiverName.copyNimTree(), receiverType.copyNimTree()),
  )
  setter[6] = propertyFieldBody(prop, receiverName, setter = true)

  result.add getter
  result.add setter

proc hasPragma(node: NimNode, name: string): bool =
  if node.kind != nnkPragma:
    return false
  for item in node:
    if item.kind == nnkIdent and item.eqIdent(name):
      return true

proc pragmaValue(node: NimNode, name: string): NimNode =
  if node.kind != nnkPragma:
    return nil
  for item in node:
    if item.kind == nnkExprColonExpr and item.len == 2 and item[0].eqIdent(name):
      return item[1]

proc stripPragma(node: NimNode, name: string): NimNode =
  result = node.copyNimTree()
  if result.kind != nnkPragma:
    return

  let pragmas = nnkPragma.newTree()
  for item in result:
    if item.kind == nnkIdent and item.eqIdent(name):
      continue
    if item.kind == nnkExprColonExpr and item.len == 2 and item[0].eqIdent(name):
      continue
    pragmas.add item

  if pragmas.len == 0:
    result = newEmptyNode()
  else:
    result = pragmas

proc methodIsOptional(node: NimNode): bool =
  node.kind == nnkMethodDef and node[4].hasPragma("optional")

proc procIsSignal(node: NimNode): bool =
  node.kind == nnkProcDef and node[4].hasPragma("signal")

proc procIsSlot(node: NimNode): bool =
  node.kind == nnkProcDef and
    (node[4].hasPragma("slot") or not node[4].pragmaValue("slotFor").isNil)

proc procSlotEventName(node: NimNode): string =
  let slotFor = node[4].pragmaValue("slotFor")
  if slotFor.isNil:
    return selectorIdentName(node[0])
  selectorIdentName(slotFor)

proc slotPragma(node: NimNode): NimNode =
  result = node.copyNimTree()
  result[4] = result[4].stripPragma("slotFor")

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

proc slotArgsType(params: NimNode, firstArg: int): NimNode =
  if params.len == firstArg:
    return nnkTupleTy.newTree()

  result = nnkTupleConstr.newTree()
  for idx in firstArg ..< params.len:
    let arg = params[idx]
    if arg.kind != nnkIdentDefs:
      error("slot arguments must be named parameters", arg)
    let argType = arg[^2]
    for nameIdx in 0 ..< arg.len - 2:
      result.add argType.copyNimTree()

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

proc selectorImplNode(p: NimNode, runtimeSelectorName = ""): NimNode

proc selectorDeclaration(node: NimNode, runtimeSelectorName = ""): NimNode =
  selectorImplNode(selectorPragma(node), runtimeSelectorName)

when sigilsClosuresEnabled:
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
      error("selector closure receiver must be a single named parameter",
          params[1])
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
      argsTypeAlias = genSym(nskType, "SelectorClosureArgs")
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
          var `argsIdent` = `invocation`.argsAs(`argsTypeAlias`)
          `call`
          `invocation`.setResult(())
      else:
        quote do:
          var `argsIdent` = `invocation`.argsAs(`argsTypeAlias`)
          `invocation`.setResult(`call`)

    result = quote do:
      block:
        type `argsTypeAlias` = `argsType`
        let `callback` = `blk`
        var `selectorType` {.used.}: typeof(`selector`)
        var `closureSelectorType` {.used.}: Selector[`argsTypeAlias`, `retType`]

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

proc selectorImplNode(p: NimNode, runtimeSelectorName = ""): NimNode =
  if p.kind != nnkMethodDef:
    error("selector pragma can only be used on a method", p)

  let
    selectorSymbolName = selectorIdentName(p[0])
    selectorRuntimeName =
      if runtimeSelectorName.len == 0:
        selectorSymbolName
      else:
        runtimeSelectorName
    selectorName = newStrLitNode(selectorRuntimeName)
    params = p[3]
    retType =
      if params[0].kind == nnkEmpty:
        nnkTupleTy.newTree()
      else:
        params[0].copyNimTree()

  checkSigilNameLength(selectorRuntimeName, p[0], "selector name")

  if p[6].kind == nnkEmpty:
    let
      selectorProc = p[0].copyNimTree()
      selectorValueProc = genSym(nskTemplate, selectorSymbolName & "Selector")
      selectorValueCache = genSym(nskLet,
          selectorSymbolName & "SelectorValue")
      directProc = genSym(nskProc, selectorSymbolName & "Send")
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
      let `selectorValueCache` =
        initSelector[`argsType`, `retType`](`selectorName`)

      template `selectorValueProc`(): untyped =
        `selectorValueCache`

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
      implProc = genSym(nskProc, selectorSymbolName & "Impl")
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
          var `argsIdent` = `invocation`.argsAs(`argsType`)
          `call`
          `invocation`.setResult(())
      else:
        quote do:
          var `argsIdent` = `invocation`.argsAs(`argsType`)
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

macro selectorImpl(p: untyped): untyped =
  selectorImplNode(p)

template selector*(p: untyped): untyped =
  selectorImpl(p)

macro property*(spec: untyped): untyped =
  ## Declare getter and setter selectors for a property.
  if spec.kind != nnkInfix or spec.len != 3 or not spec[0].eqIdent("->"):
    error("property declarations use: property name -> Type", spec)

  var field: NimNode
  var nilPolicy = propertyNilUnchecked
  let valueType = propertyValueType(spec[2], field, nilPolicy)
  if not field.isNil:
    error(
      "property field pragma requires a receiver-bound protocol implementation",
      spec,
    )
  if nilPolicy != propertyNilUnchecked:
    error("property nil policy requires a field pragma", spec)

  result = newStmtList()
  for item in propertyMethods(spec[1], valueType):
    result.add selectorDeclaration(item)

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
        var `argsIdent` = `invocation`.argsAs(`argsType`)
        `call`
        `invocation`.setResult(())
    else:
      quote do:
        var `argsIdent` = `invocation`.argsAs(`argsType`)
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
    propertyReceiver: NimNode = nil,
    observers: NimNode = nil,
): NimNode =
  var
    defs: seq[NimNode]
    bindings: seq[NimNode]

  for item in body:
    if item.procIsSignal or item.procIsSlot:
      discard
    else:
      let property = item.protocolProperty()
      if property.found:
        if not allowProperties:
          error("protocol implementations must contain method declarations", item)
        if not property.prop.field.isNil:
          if propertyReceiver.isNil:
            error(
              "property field pragma requires a receiver-bound protocol implementation",
              item,
            )
          for propertyMethod in propertyImplementationMethods(
              property.prop, propertyReceiver):
            let binding = implementMethodBinding(propertyMethod)
            defs.add binding.defs
            bindings.add binding.binding
      else:
        let binding = implementMethodBinding(item)
        defs.add binding.defs
        bindings.add binding.binding

  let methods = nnkBracket.newTree(bindings)
  let observerBindings =
    if observers.isNil:
      nnkBracket.newTree()
    else:
      observers.copyNimTree()
  let value =
    if receiver.isNil:
      newCall(
        bindSym"initProtocolImplementation",
        protocol.copyNimTree(),
        methods,
        observerBindings,
      )
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

proc protocolSlotReceiverType(item: NimNode): NimNode
proc validateProtocolReceiver(item: NimNode, receiver: NimNode)

proc implementVariant(
    variant: NimNode,
    protocol: NimNode,
    body: NimNode,
    receiver: NimNode = nil,
): NimNode =
  let
    variantType = variant.copyNimTree()
    variantTypeUse = ident(selectorIdentName(variant))

  var
    receiverType: NimNode
    slotDecls = newStmtList()
    slotChecks = newStmtList()
    observerBindings = nnkBracket.newTree()
    connectorDefs = newStmtList()
    slotAliases: seq[tuple[name: string, eventName: string]]

  for item in body:
    if item.procIsSignal:
      error("named protocol implementations cannot declare signals", item)
    if not receiver.isNil and item.kind == nnkMethodDef:
      validateProtocolReceiver(item, receiver)
    if not item.procIsSlot:
      continue

    let itemReceiver = protocolSlotReceiverType(item)
    if not receiver.isNil and itemReceiver.repr != receiver.repr:
      error("protocol implementation slot receiver must be " & receiver.repr,
        itemReceiver)
    if receiverType.isNil:
      receiverType = itemReceiver
    elif receiverType.repr != itemReceiver.repr:
      error("protocol implementation slots must use the same receiver type",
          itemReceiver)

    slotDecls.add newCall(
      bindSym"rpcImpl",
      item.slotPragma(),
      newNilLit(),
      newNilLit(),
    )
    slotChecks.add protocolSignalSlotCheckCall(
      protocol,
      newLit(item.procSlotEventName()),
      itemReceiver,
      ident(selectorIdentName(item[0])),
    )
    slotAliases.add (selectorIdentName(item[0]), item.procSlotEventName())

  if not receiverType.isNil:
    let
      connectName = protocolConnectIdent(variant)
      disconnectName = protocolDisconnectIdent(variant)
      connectCallName = ident("connect" & selectorIdentName(variant) &
        "Protocol")
      disconnectCallName = ident("disconnect" & selectorIdentName(variant) &
        "Protocol")
      connectRuntimeName = protocolConnectRuntimeIdent(variant)
      disconnectRuntimeName = protocolDisconnectRuntimeIdent(variant)
      observerSource = newIdentNode("sigilsProtocolSource")
      observerTarget = newIdentNode("sigilsProtocolObserver")
      observerReceiver = newIdentNode("sigilsProtocolReceiver")
      connectProtocolCall = protocolObserverCall(
        protocol, observerSource, observerReceiver
      )
      disconnectProtocolCall = protocolObserverCall(
        protocol, observerSource, observerReceiver, disconnect = true
      )
    var
      connectAliases = newStmtList(connectProtocolCall)
      disconnectAliases = newStmtList(disconnectProtocolCall)
    for slot in slotAliases:
      if slot.name != slot.eventName:
        connectAliases.add protocolObserverSlotCall(
          protocol,
          newLit(slot.eventName),
          observerSource,
          observerReceiver,
          ident(slot.name),
        )
        disconnectAliases.add protocolObserverSlotCall(
          protocol,
          newLit(slot.eventName),
          observerSource,
          observerReceiver,
          ident(slot.name),
          disconnect = true,
        )

    connectorDefs.add quote do:
      template `connectName`(
          `observerSource`, `observerTarget`: untyped
      ): untyped {.used.} =
        block:
          when typeof(`observerTarget`) is `receiverType`:
            let `observerReceiver` = `observerTarget`
          else:
            let `observerReceiver` = `receiverType`(`observerTarget`)
          if not `observerReceiver`.isNil:
            `connectAliases`

      template `disconnectName`(
          `observerSource`, `observerTarget`: untyped
      ): untyped {.used.} =
        block:
          when typeof(`observerTarget`) is `receiverType`:
            let `observerReceiver` = `observerTarget`
          else:
            let `observerReceiver` = `receiverType`(`observerTarget`)
          if not `observerReceiver`.isNil:
            `disconnectAliases`

      proc `connectRuntimeName`(
          `observerSource`: Agent, `observerTarget`: Agent
      ) {.nimcall, used.} =
        `connectCallName`(`observerSource`, `observerTarget`)

      proc `disconnectRuntimeName`(
          `observerSource`: Agent, `observerTarget`: Agent
      ) {.nimcall, used.} =
        `disconnectCallName`(`observerSource`, `observerTarget`)

    observerBindings.add newCall(
      bindSym"protocolObserver",
      protocol.copyNimTree(),
      newLit(selectorIdentName(variant)),
      connectRuntimeName,
      disconnectRuntimeName,
    )

  let implementation = implementBlock(
    protocol,
    body,
    allowProperties = not receiver.isNil,
    propertyReceiver = receiver,
    observers = observerBindings,
  )

  result = quote do:
    type `variantType` = object

    `slotDecls`
    `slotChecks`
    `connectorDefs`

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

proc validateProtocolSlotReceiver(item: NimNode, receiver: NimNode) =
  let params = item[3]
  if params.len < 2:
    error("receiver-bound protocol slot declarations must take a receiver", params)
  if params[1].kind != nnkIdentDefs or params[1].len != 3:
    error("protocol slot receiver must be a single named parameter", params[1])
  if params[1][1].repr != receiver.repr:
    error("protocol slot receiver must be " & receiver.repr, params[1][1])

proc protocolSlotReceiverType(item: NimNode): NimNode =
  let params = item[3]
  if params.len < 2:
    error("protocol slot declarations must take a receiver", params)
  if params[1].kind != nnkIdentDefs or params[1].len != 3:
    error("protocol slot receiver must be a single named parameter", params[1])
  result = params[1][1].copyNimTree()

proc protocolSlotCheck(
    item: NimNode, firstArg: int, receiver: NimNode
): NimNode =
  let
    slotName = selectorIdentName(item[0])
    slotIdent = ident(slotName)
    argsType = slotArgsType(item[3], firstArg)
    missingMessage = "missing protocol slot " & slotName
    mismatchMessage = "protocol slot " & slotName & " has the wrong signature"

  result = quote do:
    block:
      when compiles(SignalTypes.`slotIdent`(`receiver`)):
        when typeof(SignalTypes.`slotIdent`(`receiver`)) is `argsType`:
          discard
        else:
          {.error: `mismatchMessage`.}
      else:
        {.error: `missingMessage`.}

proc protocolSignalSlotCheck(
    signalName: string,
    sourceType: NimNode,
    receiver: NimNode,
    slotIdent: NimNode = nil,
): NimNode =
  let
    signalIdent = ident(signalName)
    resolvedSlotIdent =
      if slotIdent.isNil:
        signalIdent
      else:
        slotIdent.copyNimTree()
    resolvedSlotName = selectorIdentName(resolvedSlotIdent)
    missingMessage = "missing protocol signal slot " & resolvedSlotName &
      " for event " & signalName
    mismatchMessage = "protocol signal slot " & resolvedSlotName &
      " for event " & signalName &
      " has the wrong signature"

  result = quote do:
    block:
      when compiles(`resolvedSlotIdent`(`receiver`)):
        when typeof(SignalTypes.`signalIdent`(`sourceType`)) is typeof(
            SignalTypes.`resolvedSlotIdent`(`receiver`)
        ):
          discard
        else:
          {.error: `mismatchMessage`.}
      else:
        {.error: `missingMessage`.}

proc protocolObserverStatement(
    eventName: string,
    sourceType: NimNode,
    source: NimNode,
    observer: NimNode,
    slotName = "",
    disconnect = false,
): NimNode =
  let
    actionName =
      if disconnect:
        "disconnect"
      else:
        "connect"
    sourceName = source.repr
    sourceTypeName = sourceType.repr
    observerName = observer.repr
    signalSourceName = "sigilsProtocolSignalSource"
    resolvedSlotName =
      if slotName.len == 0:
        eventName
      else:
        slotName
    call = actionName & "(" & signalSourceName & ", " & eventName & ", " &
      observerName & ", " & resolvedSlotName & ")"

  result = parseStmt(
    "block:\n" &
      "  when typeof(" & sourceName & ") is " & sourceTypeName & ":\n" &
      "    let " & signalSourceName & " = " & sourceName & "\n" &
      "  else:\n" &
      "    let " & signalSourceName & " = " & sourceTypeName & "(" &
    sourceName & ")\n" &
      "  if not " & signalSourceName & ".isNil:\n" &
      "    when compiles(" & call & "):\n" &
      "      " & call & "\n"
  )

proc addProtocolRequirement(
    selectorDecls: var seq[NimNode],
    reqs: var seq[NimNode],
    selectors: var seq[string],
    item: NimNode,
    firstArg: int,
    required: bool,
    protocolName: string,
    selectorScope: SelectorScope,
) =
  if item.kind != nnkMethodDef:
    error("protocol requirements must be method declarations", item)

  let
    selectorName = selectorIdentName(item[0])
    runtimeSelectorName = scopedSelectorName(protocolName, selectorName,
        selectorScope)
  if selectorName in selectors:
    return
  selectors.add selectorName

  let requirementMethod = protocolRequirementMethod(item, firstArg)
  selectorDecls.add selectorDeclaration(requirementMethod, runtimeSelectorName)
  reqs.add newCall(
    bindSym"requirement",
    ident(selectorName),
    newLit(required),
    newLit(requirementMethod.repr),
  )

proc addProtocolSignal(
    signalDecls: var seq[NimNode],
    sigs: var seq[NimNode],
    signals: var seq[string],
    signalSources: var seq[tuple[name: string, sourceType: NimNode]],
    item: NimNode,
) =
  if not item.procIsSignal:
    error("protocol signal declarations must be procs with {.signal.}", item)
  if item[6].kind != nnkEmpty:
    error("protocol signal declarations cannot have implementations", item)
  if item[3].len < 2:
    error("protocol signal declarations must take a signal source argument",
        item[3])
  if item[3][1].kind != nnkIdentDefs or item[3][1].len != 3:
    error("protocol signal source must be a single named parameter", item[3][1])

  let signalName = selectorIdentName(item[0])
  if signalName in signals:
    return
  signals.add signalName
  signalSources.add (signalName, item[3][1][1].copyNimTree())

  signalDecls.add newCall(
    bindSym"rpcImpl",
    item.copyNimTree(),
    newLit("signal"),
    newNilLit(),
  )
  sigs.add newCall(
    bindSym"protocolSignal",
    newLit(signalName),
    newLit(item.repr),
  )

proc addProtocolSlot(
    slotDecls: var seq[NimNode],
    slotChecks: var seq[NimNode],
    slots: var seq[NimNode],
    slotNames: var seq[tuple[name: string, eventName: string]],
    item: NimNode,
    firstArg: int,
    receiver: NimNode,
    checkReceiver: NimNode,
) =
  if not item.procIsSlot:
    error("protocol slot declarations must be procs with {.slot.}", item)
  if receiver.isNil and item[6].kind != nnkEmpty:
    error("protocol slot declarations cannot have implementations without a receiver",
        item)
  if not receiver.isNil:
    validateProtocolSlotReceiver(item, receiver)

  let
    slotName = selectorIdentName(item[0])
    eventName = item.procSlotEventName()
  for slot in slotNames:
    if slot.name == slotName:
      return
  slotNames.add (slotName, eventName)

  if not receiver.isNil:
    slotDecls.add newCall(
      bindSym"rpcImpl",
      item.slotPragma(),
      newNilLit(),
      newNilLit(),
    )

  slotChecks.add protocolSlotCheck(item, firstArg, checkReceiver)
  slots.add newCall(
    bindSym"protocolSlot",
    newLit(slotName),
    newLit(item.repr),
    newLit(eventName),
  )

proc addIncludedProtocols(result: var seq[NimNode], node: NimNode) =
  if node.kind == nnkInfix and node.len == 3 and node[0].eqIdent(","):
    result.addIncludedProtocols(node[1])
    result.addIncludedProtocols(node[2])
  elif node.kind in {nnkPar, nnkTupleConstr}:
    for item in node:
      result.addIncludedProtocols(item)
  elif node.kind != nnkEmpty:
    result.add node.copyNimTree()

proc protocolBodyIncludes(item: NimNode): tuple[matched: bool,
    protocols: seq[NimNode]] =
  if item.kind in {nnkCommand, nnkCall} and item.len >= 2 and
      item[0].eqIdent("includes"):
    result.matched = true
    for idx in 1 ..< item.len:
      result.protocols.addIncludedProtocols(item[idx])

proc splitProtocolBody(body: NimNode): tuple[body: NimNode,
    inherited: seq[NimNode]] =
  result.body = newStmtList()
  for section in body:
    let includes = protocolBodyIncludes(section)
    if includes.matched:
      if includes.protocols.len == 0:
        error("includes requires at least one protocol", section)
      result.inherited.add includes.protocols
    else:
      result.body.add section.copyNimTree()

proc protocolDeclaration(
    name: NimNode,
    body: NimNode,
    firstArg = 1,
    receiver: NimNode = nil,
    inherited: openArray[NimNode] = [],
    selectorScope = selectorScopeNone,
): NimNode =
  let split = splitProtocolBody(body)
  var allInherited = newSeq[NimNode]()
  for inheritedProtocol in inherited:
    allInherited.add inheritedProtocol.copyNimTree()
  allInherited.add split.inherited

  let
    protocolNameString = selectorIdentName(name)
    protocolName = newStrLitNode(protocolNameString)
  checkSigilNameLength(protocolNameString, name, "protocol name")

  var
    selectorDecls: seq[NimNode]
    signalDecls: seq[NimNode]
    slotDecls: seq[NimNode]
    reqs: seq[NimNode]
    sigs: seq[NimNode]
    slts: seq[NimNode]
    slotChecks: seq[NimNode]
    selectors: seq[string]
    signals: seq[string]
    signalSources: seq[tuple[name: string, sourceType: NimNode]]
    slotNames: seq[tuple[name: string, eventName: string]]

  let checkReceiver = ident("receiver")

  for section in split.body:
    let property = section.protocolProperty()
    if property.found:
      if not property.prop.field.isNil and receiver.isNil:
        error(
          "property field pragma requires a receiver-bound protocol implementation",
          section,
        )
      for propertyDecl in propertyMethods(property.prop):
        addProtocolRequirement(
          selectorDecls,
          reqs,
          selectors,
          propertyDecl,
          1,
          not propertyDecl.methodIsOptional,
          protocolNameString,
          selectorScope,
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
        protocolNameString,
        selectorScope,
      )
    elif section.procIsSignal:
      addProtocolSignal(
        signalDecls,
        sigs,
        signals,
        signalSources,
        section,
      )
    elif section.procIsSlot:
      addProtocolSlot(
        slotDecls,
        slotChecks,
        slts,
        slotNames,
        section,
        if receiver.isNil: 1 else: 2,
        receiver,
        checkReceiver,
      )
    else:
      error("protocol bodies must contain method requirements, properties, signals, or slots",
          section)

  result = newStmtList()
  for selectorDecl in selectorDecls:
    result.add selectorDecl
  for signalDecl in signalDecls:
    result.add signalDecl
  for slotDecl in slotDecls:
    result.add slotDecl

  let checkName = protocolSlotCheckIdent(name)
  let
    hasSignalName = protocolHasSignalNameIdent(name)
    signalSlotCheckName = protocolSignalSlotCheckIdent(name)
    signalNameParam = newIdentNode("sigilsProtocolSignalName")
    slotNameParam = newIdentNode("sigilsProtocolSlotName")
  var checkBody = newStmtList()
  for inheritedProtocol in allInherited:
    checkBody.add protocolSlotCheckCall(inheritedProtocol, checkReceiver)
  for slotCheck in slotChecks:
    checkBody.add slotCheck
  if checkBody.len == 0:
    checkBody.add quote do:
      discard

  result.add quote do:
    template `checkName`(`checkReceiver`: typedesc): untyped {.used.} =
      block:
        `checkBody`

  var hasSignalNameExpr = newLit(false)
  for inheritedProtocol in allInherited:
    hasSignalNameExpr = nnkInfix.newTree(
      ident"or",
      hasSignalNameExpr,
      protocolHasSignalNameCall(inheritedProtocol, signalNameParam),
    )
  for signal in signalSources:
    hasSignalNameExpr = nnkInfix.newTree(
      ident"or",
      hasSignalNameExpr,
      nnkInfix.newTree(ident"==", signalNameParam, newLit(signal.name)),
    )

  result.add quote do:
    template `hasSignalName`(
        `signalNameParam`: static string
    ): bool {.used.} =
      `hasSignalNameExpr`

  let unsupportedSignalSlotMessage =
    "protocol slot does not match any signal in protocol " & protocolNameString
  var signalSlotCheckBody = nnkWhenStmt.newTree()
  for inheritedProtocol in allInherited:
    signalSlotCheckBody.add nnkElifBranch.newTree(
      protocolHasSignalNameCall(inheritedProtocol, signalNameParam),
      newStmtList(
        protocolSignalSlotCheckCall(
          inheritedProtocol,
          signalNameParam,
          checkReceiver,
          slotNameParam,
      )
    ),
    )
  for signal in signalSources:
    signalSlotCheckBody.add nnkElifBranch.newTree(
      nnkInfix.newTree(ident"==", signalNameParam, newLit(signal.name)),
      newStmtList(
        protocolSignalSlotCheck(
          signal.name,
          signal.sourceType,
          checkReceiver,
          slotNameParam,
      )
    ),
    )
  signalSlotCheckBody.add nnkElse.newTree(newStmtList(quote do:
    {.error: `unsupportedSignalSlotMessage`.}
  ))

  result.add quote do:
    template `signalSlotCheckName`(
        `signalNameParam`: static string,
        `checkReceiver`: typedesc,
        `slotNameParam`: untyped,
    ): untyped {.used.} =
      block:
        `signalSlotCheckBody`

  if not receiver.isNil and allInherited.len > 0:
    for slot in slotNames:
      result.add protocolSignalSlotCheckCall(
        name,
        newLit(slot.eventName),
        receiver,
        ident(slot.name),
      )

  let
    connectName = protocolConnectIdent(name)
    disconnectName = protocolDisconnectIdent(name)
    connectSlotName = protocolConnectSlotIdent(name)
    disconnectSlotName = protocolDisconnectSlotIdent(name)
    connectCallName = ident("connect" & selectorIdentName(name) & "Protocol")
    disconnectCallName = ident("disconnect" & selectorIdentName(name) & "Protocol")
    connectRuntimeName = protocolConnectRuntimeIdent(name)
    disconnectRuntimeName = protocolDisconnectRuntimeIdent(name)
    observerSource = newIdentNode("sigilsProtocolSource")
    observerTarget = newIdentNode("sigilsProtocolObserver")
    observerReceiver = newIdentNode("sigilsProtocolReceiver")
    observerEventName = newIdentNode("sigilsProtocolEventName")
    observerSlot = newIdentNode("sigilsProtocolSlot")
    observerForConnect =
      if receiver.isNil:
        observerTarget
      else:
        observerReceiver
  var
    connectBody = newStmtList()
    disconnectBody = newStmtList()
    connectSlotBody = newStmtList()
    disconnectSlotBody = newStmtList()

  for inheritedProtocol in allInherited:
    connectBody.add protocolObserverCall(inheritedProtocol, observerSource,
        observerForConnect)
    disconnectBody.add protocolObserverCall(inheritedProtocol, observerSource,
        observerForConnect, disconnect = true)
    connectSlotBody.add nnkWhenStmt.newTree(
      nnkElifBranch.newTree(
        protocolHasSignalNameCall(inheritedProtocol, observerEventName),
        newStmtList(
          protocolObserverSlotCall(
            inheritedProtocol,
            observerEventName,
            observerSource,
            observerForConnect,
            observerSlot,
      )
    ),
      )
    )
    disconnectSlotBody.add nnkWhenStmt.newTree(
      nnkElifBranch.newTree(
        protocolHasSignalNameCall(inheritedProtocol, observerEventName),
        newStmtList(
          protocolObserverSlotCall(
            inheritedProtocol,
            observerEventName,
            observerSource,
            observerForConnect,
            observerSlot,
            disconnect = true,
      )
    ),
      )
    )

  for signal in signalSources:
    connectBody.add protocolObserverStatement(signal.name,
        signal.sourceType, observerSource, observerForConnect)
    disconnectBody.add protocolObserverStatement(signal.name,
        signal.sourceType, observerSource, observerForConnect,
        disconnect = true)
    connectSlotBody.add nnkWhenStmt.newTree(
      nnkElifBranch.newTree(
        nnkInfix.newTree(ident"==", observerEventName, newLit(signal.name)),
        newStmtList(
          protocolObserverStatement(
            signal.name,
            signal.sourceType,
            observerSource,
            observerForConnect,
            slotName = observerSlot.repr,
      )
    ),
      )
    )
    disconnectSlotBody.add nnkWhenStmt.newTree(
      nnkElifBranch.newTree(
        nnkInfix.newTree(ident"==", observerEventName, newLit(signal.name)),
        newStmtList(
          protocolObserverStatement(
            signal.name,
            signal.sourceType,
            observerSource,
            observerForConnect,
            slotName = observerSlot.repr,
            disconnect = true,
      )
    ),
      )
    )

  for slot in slotNames:
    if slot.name != slot.eventName:
      connectBody.add protocolObserverSlotCall(
        name,
        newLit(slot.eventName),
        observerSource,
        observerForConnect,
        ident(slot.name),
      )
      disconnectBody.add protocolObserverSlotCall(
        name,
        newLit(slot.eventName),
        observerSource,
        observerForConnect,
        ident(slot.name),
        disconnect = true,
      )

  if connectBody.len == 0:
    connectBody.add quote do:
      discard
  if disconnectBody.len == 0:
    disconnectBody.add quote do:
      discard
  if connectSlotBody.len == 0:
    connectSlotBody.add quote do:
      discard
  if disconnectSlotBody.len == 0:
    disconnectSlotBody.add quote do:
      discard

  if receiver.isNil:
    result.add quote do:
      template `connectSlotName`(
          `observerEventName`: static string,
          `observerSource`,
          `observerTarget`,
          `observerSlot`: untyped,
      ): untyped {.used.} =
        block:
          `connectSlotBody`

      template `disconnectSlotName`(
          `observerEventName`: static string,
          `observerSource`,
          `observerTarget`,
          `observerSlot`: untyped,
      ): untyped {.used.} =
        block:
          `disconnectSlotBody`

      template `connectName`(
          `observerSource`, `observerTarget`: untyped
      ): untyped {.used.} =
        block:
          `connectBody`

      template `disconnectName`(
          `observerSource`, `observerTarget`: untyped
      ): untyped {.used.} =
        block:
          `disconnectBody`
  else:
    let receiverType = receiver.copyNimTree()
    result.add quote do:
      template `connectSlotName`(
          `observerEventName`: static string,
          `observerSource`,
          `observerTarget`,
          `observerSlot`: untyped,
      ): untyped {.used.} =
        block:
          when typeof(`observerTarget`) is `receiverType`:
            let `observerReceiver` = `observerTarget`
          else:
            let `observerReceiver` = `receiverType`(`observerTarget`)
          if not `observerReceiver`.isNil:
            `connectSlotBody`

      template `disconnectSlotName`(
          `observerEventName`: static string,
          `observerSource`,
          `observerTarget`,
          `observerSlot`: untyped,
      ): untyped {.used.} =
        block:
          when typeof(`observerTarget`) is `receiverType`:
            let `observerReceiver` = `observerTarget`
          else:
            let `observerReceiver` = `receiverType`(`observerTarget`)
          if not `observerReceiver`.isNil:
            `disconnectSlotBody`

      template `connectName`(
          `observerSource`, `observerTarget`: untyped
      ): untyped {.used.} =
        block:
          when typeof(`observerTarget`) is `receiverType`:
            let `observerReceiver` = `observerTarget`
          else:
            let `observerReceiver` = `receiverType`(`observerTarget`)
          if not `observerReceiver`.isNil:
            `connectBody`

      template `disconnectName`(
          `observerSource`, `observerTarget`: untyped
      ): untyped {.used.} =
        block:
          when typeof(`observerTarget`) is `receiverType`:
            let `observerReceiver` = `observerTarget`
          else:
            let `observerReceiver` = `receiverType`(`observerTarget`)
          if not `observerReceiver`.isNil:
            `disconnectBody`

  result.add quote do:
    proc `connectRuntimeName`(
        `observerSource`: Agent, `observerTarget`: Agent
    ) {.nimcall, used.} =
      `connectCallName`(`observerSource`, `observerTarget`)

    proc `disconnectRuntimeName`(
        `observerSource`: Agent, `observerTarget`: Agent
    ) {.nimcall, used.} =
      `disconnectCallName`(`observerSource`, `observerTarget`)

  let protocolCall =
    if allInherited.len == 0:
      newCall(
        bindSym"initProtocol",
        protocolName,
        nnkBracket.newTree(reqs),
        nnkBracket.newTree(sigs),
        nnkBracket.newTree(slts),
      )
    else:
      newCall(
        bindSym"initProtocol",
        protocolName,
        nnkBracket.newTree(allInherited),
        nnkBracket.newTree(reqs),
        nnkBracket.newTree(sigs),
        nnkBracket.newTree(slts),
      )

  result.add newLetStmt(selectorIdent(selectorIdentName(name), true), protocolCall)

proc implementProtocolForReceiver(
    protocol: NimNode,
    receiver: NimNode,
    body: NimNode,
    inherited: openArray[NimNode] = [],
    selectorScope = selectorScopeNone,
): NimNode =
  let split = splitProtocolBody(body)
  var allInherited = newSeq[NimNode]()
  for inheritedProtocol in inherited:
    allInherited.add inheritedProtocol.copyNimTree()
  allInherited.add split.inherited

  let observerBindings = nnkBracket.newTree()
  observerBindings.add newCall(
    bindSym"protocolObserver",
    protocol.copyNimTree(),
    protocol.copyNimTree(),
    protocolConnectRuntimeIdent(protocol),
    protocolDisconnectRuntimeIdent(protocol),
  )
  for inheritedProtocol in allInherited:
    observerBindings.add newCall(
      bindSym"protocolObserver",
      inheritedProtocol.copyNimTree(),
      protocol.copyNimTree(),
      protocolConnectRuntimeIdent(protocol),
      protocolDisconnectRuntimeIdent(protocol),
    )

  let
    protocolDecl = protocolDeclaration(protocol, split.body, 2, receiver,
        inherited = allInherited, selectorScope = selectorScope)
    implementation = implementBlock(protocol, split.body,
        allowProperties = true, propertyReceiver = receiver,
        observers = observerBindings)
    receiverType = receiver.copyNimTree()

  result = quote do:
    `protocolDecl`

    proc proto*(_: typedesc[`receiverType`]): ProtocolImplementation =
      `implementation`

macro protocol*(name: untyped, body: untyped): untyped =
  ## Declare a protocol or a named implementation variant for a protocol.
  if name.kind == nnkInfix and name.len == 3 and name[0].eqIdent("from") and
      name[1].kind == nnkInfix and name[1].len == 3 and name[1][0].eqIdent("of"):
    return implementVariant(name[1][1], name[1][2], body, name[2])
  if name.kind == nnkInfix and name.len == 3 and name[0].eqIdent("of"):
    if name[2].kind == nnkInfix and name[2].len == 3 and name[2][0].eqIdent("from"):
      return implementVariant(name[1], name[2][1], body, name[2][2])
    return implementVariant(name[1], name[2], body)
  if name.kind == nnkInfix and name.len == 3 and name[0].eqIdent("from"):
    let parsed = protocolNameAndScope(name[1])
    return implementProtocolForReceiver(parsed.name, name[2], body,
        selectorScope = parsed.selectorScope)
  if name.kind == nnkCommand and name.len == 2 and
      name[1].kind == nnkCommand and name[1].len == 2 and
      name[1][0].kind == nnkAccQuoted and
      name[1][0].len == 1 and name[1][0][0].eqIdent("for"):
    let parsed = protocolNameAndScope(name[0])
    return implementProtocolForReceiver(parsed.name, name[1][1], body,
        selectorScope = parsed.selectorScope)

  let parsed = protocolNameAndScope(name)
  protocolDeclaration(parsed.name, body, selectorScope = parsed.selectorScope)

macro protocol*(name: untyped, receiver: untyped, body: untyped): untyped =
  ## Declare a protocol and its default implementation for a receiver type.
  let parsed = protocolNameAndScope(name)
  implementProtocolForReceiver(parsed.name, receiver, body,
      selectorScope = parsed.selectorScope)

macro checkProtocolSlots*(receiver: untyped, protocol: untyped): untyped =
  ## Check at compile time that a receiver type exposes a protocol's slots.
  protocolSlotCheckCall(protocol, receiver)

macro requireProtocolSlots*(receiver: untyped, protocol: untyped): untyped =
  ## Check at compile time that a receiver type exposes a protocol's slots.
  protocolSlotCheckCall(protocol, receiver)

macro connectProtocol*(
    source: untyped, observer: untyped, protocol: untyped
): untyped =
  ## Connect protocol-declared signals to matching protocol-declared observer slots.
  protocolObserverCall(protocol, source, observer)

macro disconnectProtocol*(
    source: untyped, observer: untyped, protocol: untyped
): untyped =
  ## Disconnect protocol-declared signals from matching protocol-declared observer slots.
  protocolObserverCall(protocol, source, observer, disconnect = true)

macro observeProtocol*(
    observer: untyped, source: untyped, protocol: untyped
): untyped =
  ## Observe protocol-declared signals from a source.
  protocolObserverCall(protocol, source, observer)

macro unobserveProtocol*(
    observer: untyped, source: untyped, protocol: untyped
): untyped =
  ## Stop observing protocol-declared signals from a source.
  protocolObserverCall(protocol, source, observer, disconnect = true)

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

proc initLocalInvocation[A, R](
    selector: SigilName, args: var A, value: var R
): Invocation =
  result = Invocation(
    selector: selector,
    handled: false,
    argsPtr: addr args,
    resultPtr: addr value,
  )

proc argsAs*[A](invocation: Invocation, _: typedesc[A]): A =
  if not invocation.argsPtr.isNil:
    result = cast[ptr A](invocation.argsPtr)[]
  else:
    rpcUnpack(result, invocation.params)

proc setResult*[R](invocation: var Invocation, value: sink R) =
  if not invocation.resultPtr.isNil:
    cast[ptr R](invocation.resultPtr)[] = ensureMove value
    invocation.resultWritten = true
  else:
    invocation.result = rpcPack(ensureMove value)
  invocation.handled = true

proc resultAs*[R](invocation: Invocation, _: typedesc[R]): R =
  if invocation.resultWritten and not invocation.resultPtr.isNil:
    result = cast[ptr R](invocation.resultPtr)[]
  else:
    rpcUnpack(result, invocation.result)

proc localMethod*(obj: DynamicAgent, selector: SigilName): DynamicMethod =
  ## Return the top local method for a selector, if one is installed.
  if obj.isNil:
    return nil
  obj.methods.methodTop(selector)

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
  if obj.isNil:
    return @[]
  obj.methods.methodStackCopy(selector)

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

proc signalNames*(protocol: SigilProtocol): seq[SigilName] =
  ## Return signal names declared by a protocol.
  for signal in protocol.signals:
    result.add signal.name

proc slotNames*(protocol: SigilProtocol): seq[SigilName] =
  ## Return slot names declared by a protocol.
  for slot in protocol.slots:
    result.add slot.name

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

proc protocolSignal*(
    protocol: SigilProtocol, name: SigilName
): Option[ProtocolSignal] =
  ## Return the protocol signal metadata for a signal name, if present.
  for signal in protocol.signals:
    if signal.name == name:
      return some(signal)

proc hasSignal*(protocol: SigilProtocol, name: SigilName): bool =
  ## Check whether a protocol declares a signal.
  protocol.protocolSignal(name).isSome

proc protocolSlot*(
    protocol: SigilProtocol, name: SigilName
): Option[ProtocolSlot] =
  ## Return the protocol slot metadata for a slot name, if present.
  for slot in protocol.slots:
    if slot.name == name:
      return some(slot)

proc hasSlot*(protocol: SigilProtocol, name: SigilName): bool =
  ## Check whether a protocol declares a slot.
  protocol.protocolSlot(name).isSome

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

proc sameProtocolObserver(a, b: ProtocolObserverBinding): bool =
  a.protocol == b.protocol and a.implementation == b.implementation

proc installProtocolObservers(
    obj: DynamicAgent, observers: openArray[ProtocolObserverBinding]
) =
  if obj.isNil:
    return

  for observer in observers:
    var idx = 0
    while idx < obj.protocolObservers.len:
      if obj.protocolObservers[idx].sameProtocolObserver(observer):
        obj.protocolObservers.delete(idx)
      else:
        inc idx
    obj.protocolObservers.add observer

proc uninstallProtocolObservers(
    obj: DynamicAgent, observers: openArray[ProtocolObserverBinding]
) =
  if obj.isNil:
    return

  for observer in observers:
    var idx = 0
    while idx < obj.protocolObservers.len:
      if obj.protocolObservers[idx].sameProtocolObserver(observer):
        obj.protocolObservers.delete(idx)
      else:
        inc idx

proc connectProtocolObservers*(
    source: Agent, observer: DynamicAgent, protocol: SigilProtocol
): bool {.discardable.} =
  ## Connect observer-installed slots for a protocol, if the observer has any.
  if source.isNil or observer.isNil:
    return false

  for binding in observer.protocolObservers:
    if binding.protocol == protocol.name:
      binding.connect(source, observer)
      result = true

proc disconnectProtocolObservers*(
    source: Agent, observer: DynamicAgent, protocol: SigilProtocol
): bool {.discardable.} =
  ## Disconnect observer-installed slots for a protocol, if the observer has any.
  if source.isNil or observer.isNil:
    return false

  for binding in observer.protocolObservers:
    if binding.protocol == protocol.name:
      binding.disconnect(source, observer)
      result = true

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

proc setProtocolDelegate*(
    source: DynamicAgent,
    currentDelegate: var DynamicAgent,
    newDelegate: DynamicAgent,
    behaviorProtocol: SigilProtocol,
    eventProtocol: SigilProtocol,
): bool {.discardable.} =
  ## Replace a selector delegate and update protocol event observation.
  if source.isNil or currentDelegate == newDelegate:
    return false

  if not newDelegate.isNil:
    discard newDelegate.adopt(behaviorProtocol)

  let oldDelegate = currentDelegate
  if not oldDelegate.isNil:
    discard disconnectProtocolObservers(source, oldDelegate, eventProtocol)

  currentDelegate = newDelegate

  if not newDelegate.isNil:
    discard connectProtocolObservers(source, newDelegate, eventProtocol)

  result = true

proc activeDispatchIndex(obj: DynamicAgent, selector: SigilName): int =
  if obj.isNil:
    return -1
  for index in countdown(obj.dispatchFrames.len - 1, 0):
    if obj.dispatchFrames[index].selector == selector:
      return obj.dispatchFrames[index].index
  -1

proc invokeLocalMethodAt(
    obj: DynamicAgent,
    selector: SigilName,
    index: int,
    fn: DynamicMethod,
    invocation: var Invocation,
): bool =
  if fn.isNil:
    return false
  let frameLen = obj.dispatchFrames.len
  obj.dispatchFrames.add DispatchFrame(selector: selector, index: index)
  try:
    fn(obj, invocation)
    result = invocation.handled
  finally:
    obj.dispatchFrames.setLen(frameLen)

proc dispatch*(obj: DynamicAgent, invocation: var Invocation): bool =
  ## Try to handle an invocation locally, then through the responder chain.
  if obj.isNil:
    return false

  var stack = obj.methodStack(invocation.selector)
  if stack.len == 0 and not obj.resolveMethodHandler.isNil and
      obj.resolveMethodHandler(obj, invocation.selector):
    stack = obj.methodStack(invocation.selector)

  if stack.len > 0:
    if obj.invokeLocalMethodAt(
      invocation.selector,
      stack.len - 1,
      stack[^1],
      invocation,
    ):
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

  var stack = obj.methodStack(invocation.selector)
  if stack.len == 0 and not obj.resolveMethodHandler.isNil and
      obj.resolveMethodHandler(obj, invocation.selector):
    stack = obj.methodStack(invocation.selector)

  if stack.len > 0:
    if obj.invokeLocalMethodAt(
      invocation.selector,
      stack.len - 1,
      stack[^1],
      invocation,
    ):
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
  var localArgs = ensureMove args
  var invocation = initLocalInvocation(selector.name, localArgs, value)
  result = obj.dispatch(invocation)
  if result and not invocation.resultWritten:
    rpcUnpack(value, invocation.result)

proc performLocal*[A, R](
    obj: DynamicAgent,
    selector: Selector[A, R],
    args: sink A,
    value: var R,
): bool =
  var localArgs = ensureMove args
  var invocation = initLocalInvocation(selector.name, localArgs, value)
  result = obj.dispatchLocal(invocation)
  if result and not invocation.resultWritten:
    rpcUnpack(value, invocation.result)

proc dispatchNextLocal*(obj: DynamicAgent, invocation: var Invocation): bool =
  ## Try lower local implementations for an invocation without walking responders.
  if obj.isNil:
    return false

  let stack = obj.methodStack(invocation.selector)
  if stack.len < 2:
    return false

  let activeIndex = obj.activeDispatchIndex(invocation.selector)
  let nextIndex =
    if activeIndex > 0:
      activeIndex - 1
    else:
      stack.len - 2
  if nextIndex < 0:
    return false

  for index in countdown(min(nextIndex, stack.len - 1), 0):
    if obj.invokeLocalMethodAt(invocation.selector, index, stack[index], invocation):
      return true

proc performNext*[A, R](
    obj: DynamicAgent,
    selector: Selector[A, R],
    args: sink A,
    value: var R,
): bool =
  ## Perform the next lower local implementation for a selector.
  var localArgs = ensureMove args
  var invocation = initLocalInvocation(selector.name, localArgs, value)
  result = obj.dispatchNextLocal(invocation)
  if result and not invocation.resultWritten:
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

proc performNext*[A, R](
    obj: DynamicAgent, selector: Selector[A, R], args: sink A
): Option[R] =
  ## Perform the next lower local implementation for an optional selector send.
  var value: R
  if obj.performNext(selector, ensureMove args, value):
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

proc trySendNext*[A, R](
    obj: DynamicAgent, selector: Selector[A, R], args: sink A
): Option[R] =
  ## Perform the next lower local implementation for an optional selector send.
  obj.performNext(selector, ensureMove args)

proc trySendNext*[R](obj: DynamicAgent, selector: Selector[tuple[], R]): Option[R] =
  ## Perform the next lower local zero-argument selector implementation.
  obj.performNext(selector, ())

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

proc sendNextIfHandled*[A, R](
    obj: DynamicAgent, selector: Selector[A, R], args: sink A
): bool =
  ## Perform the next lower local selector implementation and report handling.
  var value: R
  obj.performNext(selector, ensureMove args, value)

proc sendNextIfHandled*[R](obj: DynamicAgent, selector: Selector[tuple[], R]): bool =
  ## Perform the next lower local zero-argument selector implementation.
  var value: R
  obj.performNext(selector, (), value)

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

when sigilsClosuresEnabled:
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
  if not obj.localMethod(selector.name).isNil:
    return false
  obj.methods.putMethodStack(selector.name, @[fn])
  result = true

when sigilsClosuresEnabled:
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
    if not obj.localMethod(binding.selector).isNil:
      return false

  for binding in methods:
    obj.methods.putMethodStack(binding.selector, @[binding.implementation])
  result = true

proc replaceMethod*[A, R](
    obj: DynamicAgent,
    selector: Selector[A, R],
    fn: DynamicMethod,
): DynamicMethod {.discardable.} =
  ## Replace the local implementation and return the previous top method, if any.
  obj.methods.replaceMethodStack(selector.name, @[fn])

when sigilsClosuresEnabled:
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
    obj.methods.putMethodStack(binding.selector, @[binding.implementation])

proc removeMethod*(obj: DynamicAgent, selector: SigilName): DynamicMethod {.
    discardable.} =
  ## Remove local methods for a selector and return the previous top method.
  if not obj.isNil:
    result = obj.methods.removeMethodStack(selector)

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
  if obj.addMethods(implementation.protocol, implementation.methods):
    obj.installProtocolObservers(implementation.observers)
    result = true

proc pushMethods*(
    obj: DynamicAgent, methods: openArray[SelectorMethod]
): seq[SwizzleToken] {.discardable.} =
  ## Push selector implementations onto the local method stacks.
  for binding in methods:
    result.add SwizzleToken(
      owner: obj.unsafeWeakRef(),
      selector: binding.selector,
      depth: obj.methods.pushMethodStack(binding.selector,
          binding.implementation),
    )

proc pushMethods*(
    obj: DynamicAgent, implementation: ProtocolImplementation
): seq[SwizzleToken] {.discardable.} =
  ## Push a reusable protocol implementation, then adopt its protocol.
  result = obj.pushMethods(implementation.methods)
  discard obj.adopt(implementation.protocol)
  obj.installProtocolObservers(implementation.observers)

proc replaceMethods*(
    obj: DynamicAgent, implementation: ProtocolImplementation
): seq[DynamicMethod] {.discardable.} =
  ## Replace methods from a reusable protocol implementation, then adopt its protocol.
  result = obj.replaceMethods(implementation.protocol, implementation.methods)
  obj.installProtocolObservers(implementation.observers)

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
  obj.uninstallProtocolObservers(implementation.observers)
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
  let selectorName = selector.name
  result = SwizzleToken(
    owner: obj.unsafeWeakRef(),
    selector: selectorName,
    depth: obj.methods.pushMethodStack(selectorName, fn),
  )

proc pushMethod*[A, R](
    obj: DynamicAgent,
    selector: Selector[A, R],
    wrapper: AroundMethod,
): SwizzleToken =
  ## Push a reversible wrapper around the current local implementation.
  let previous = obj.localMethod(selector.name)
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

when sigilsClosuresEnabled:
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

  token.owner[].methods.popMethodStack(token.selector, token.depth)
