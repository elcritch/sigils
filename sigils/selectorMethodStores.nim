import std/tables

import protocol

const sigilsSelectorBinarySearchThreshold {.intdefine.} = 16

type
  SelectorMethodStoreKind = enum
    smsSmall
    smsLarge

  SelectorMethodStack[Method] = object
    selector: SigilName
    stack: seq[Method]

  SelectorMethodStore*[Method] = object
    ## Stores selector stacks as a sorted seq while small, then promotes to a
    ## table once lookups benefit more from hashing than cache-local scanning.
    case kind: SelectorMethodStoreKind
    of smsSmall:
      small: seq[SelectorMethodStack[Method]]
    of smsLarge:
      large: Table[SigilName, seq[Method]]

func useLinearSelectorScan(methodsLen: int): bool {.inline.} =
  sigilsSelectorBinarySearchThreshold > 0 and
    methodsLen < sigilsSelectorBinarySearchThreshold

func cmpSelectorName(a, b: SigilName): int {.inline.} =
  let minLen = min(a.len, b.len)
  var idx = 0
  while idx < minLen:
    if a.data[idx] < b.data[idx]:
      return -1
    if a.data[idx] > b.data[idx]:
      return 1
    idx.inc()

  if a.len < b.len:
    -1
  elif a.len > b.len:
    1
  else:
    0

proc lowerBoundMethodStack[Method](
    methods: openArray[SelectorMethodStack[Method]], selector: SigilName
): int {.inline.} =
  var
    lo = 0
    hi = methods.len
  while lo < hi:
    let mid = (lo + hi) shr 1
    if cmpSelectorName(methods[mid].selector, selector) < 0:
      lo = mid + 1
    else:
      hi = mid
  lo

proc methodStackIndex[Method](
    methods: openArray[SelectorMethodStack[Method]], selector: SigilName
): int {.inline.} =
  if useLinearSelectorScan(methods.len):
    var idx = 0
    while idx < methods.len:
      if methods[idx].selector == selector:
        return idx
      idx.inc()
    return -1

  let idx = lowerBoundMethodStack(methods, selector)
  if idx < methods.len and methods[idx].selector == selector:
    idx
  else:
    -1

proc promoteMethodStore[Method](store: var SelectorMethodStore[Method]) =
  case store.kind
  of smsLarge:
    return
  of smsSmall:
    discard

  if useLinearSelectorScan(store.small.len):
    return

  var large: Table[SigilName, seq[Method]]
  for item in store.small:
    large[item.selector] = item.stack
  store = SelectorMethodStore[Method](kind: smsLarge, large: large)

proc demoteMethodStore[Method](store: var SelectorMethodStore[Method]) =
  case store.kind
  of smsSmall:
    return
  of smsLarge:
    discard

  if not useLinearSelectorScan(store.large.len):
    return

  var small: seq[SelectorMethodStack[Method]]
  for selector, stack in store.large:
    let insertAt = lowerBoundMethodStack(small, selector)
    small.insert(SelectorMethodStack[Method](
      selector: selector,
      stack: stack,
    ), insertAt)
  store = SelectorMethodStore[Method](kind: smsSmall, small: small)

proc methodTop*[Method](
    store: var SelectorMethodStore[Method], selector: SigilName
): Method {.inline.} =
  case store.kind
  of smsLarge:
    store.large.withValue(selector, stack):
      if stack[].len > 0:
        result = stack[][^1]
  of smsSmall:
    let idx = store.small.methodStackIndex(selector)
    if idx >= 0 and store.small[idx].stack.len > 0:
      result = store.small[idx].stack[^1]

proc methodStackCopy*[Method](
    store: var SelectorMethodStore[Method], selector: SigilName
): seq[Method] =
  case store.kind
  of smsLarge:
    store.large.withValue(selector, stack):
      result = stack[]
  of smsSmall:
    let idx = store.small.methodStackIndex(selector)
    if idx >= 0:
      result = store.small[idx].stack

proc putMethodStack*[Method](
    store: var SelectorMethodStore[Method], selector: SigilName,
    stack: sink seq[Method],
) =
  case store.kind
  of smsLarge:
    if stack.len == 0:
      if selector in store.large:
        store.large.del(selector)
        store.demoteMethodStore()
    else:
      store.large[selector] = ensureMove stack
    return

  of smsSmall:
    let idx = store.small.methodStackIndex(selector)
    if idx >= 0:
      if stack.len == 0:
        store.small.delete(idx)
      else:
        store.small[idx].stack = ensureMove stack
    elif stack.len > 0:
      let insertAt = lowerBoundMethodStack(store.small, selector)
      store.small.insert(SelectorMethodStack[Method](
        selector: selector,
        stack: ensureMove stack,
      ), insertAt)
      store.promoteMethodStore()

proc replaceMethodStack*[Method](
    store: var SelectorMethodStore[Method], selector: SigilName,
    stack: sink seq[Method],
): Method =
  result = store.methodTop(selector)
  store.putMethodStack(selector, ensureMove stack)

proc removeMethodStack*[Method](
    store: var SelectorMethodStore[Method], selector: SigilName
): Method =
  result = store.methodTop(selector)
  case store.kind
  of smsLarge:
    if selector in store.large:
      store.large.del(selector)
      store.demoteMethodStore()
  of smsSmall:
    let idx = store.small.methodStackIndex(selector)
    if idx >= 0:
      store.small.delete(idx)

proc pushMethodStack*[Method](
    store: var SelectorMethodStore[Method], selector: SigilName, fn: Method
): int =
  case store.kind
  of smsLarge:
    store.large.withValue(selector, stack):
      result = stack[].len
      stack[].add fn
    do:
      store.putMethodStack(selector, @[fn])
  of smsSmall:
    let idx = store.small.methodStackIndex(selector)
    if idx >= 0:
      result = store.small[idx].stack.len
      store.small[idx].stack.add fn
    else:
      store.putMethodStack(selector, @[fn])

proc popMethodStack*[Method](
    store: var SelectorMethodStore[Method], selector: SigilName, depth: int
): bool =
  case store.kind
  of smsLarge:
    var removeStack = false
    store.large.withValue(selector, stack):
      if stack[].len != depth + 1:
        return false

      stack[].setLen(depth)
      removeStack = stack[].len == 0
      result = true
    do:
      return false

    if removeStack:
      store.large.del(selector)
      store.demoteMethodStore()
    return

  of smsSmall:
    let idx = store.small.methodStackIndex(selector)
    if idx < 0:
      return false

    if store.small[idx].stack.len != depth + 1:
      return false

    store.small[idx].stack.setLen(depth)
    if store.small[idx].stack.len == 0:
      store.small.delete(idx)
    result = true
