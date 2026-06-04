import hybridTables
import protocol

const sigilsSelectorBinarySearchThreshold {.intdefine.} = 16

type
  SelectorMethodStore*[Method] =
    HybridSigilTable[Method, sigilsSelectorBinarySearchThreshold]

proc methodTop*[Method](
    store: SelectorMethodStore[Method], selector: SigilName
): Method {.inline, gcsafe, raises: [].} =
  store.topValue(selector)

proc methodStackCopy*[Method](
    store: SelectorMethodStore[Method], selector: SigilName
): seq[Method] {.gcsafe, raises: [].} =
  store.valuesCopy(selector)

proc putMethodStack*[Method](
    store: var SelectorMethodStore[Method], selector: SigilName,
    stack: sink seq[Method],
) {.gcsafe, raises: [].} =
  store.putValues(selector, ensureMove stack)

proc replaceMethodStack*[Method](
    store: var SelectorMethodStore[Method], selector: SigilName,
    stack: sink seq[Method],
): Method {.gcsafe, raises: [].} =
  result = store.methodTop(selector)
  store.putMethodStack(selector, ensureMove stack)

proc removeMethodStack*[Method](
    store: var SelectorMethodStore[Method], selector: SigilName
): Method {.gcsafe, raises: [].} =
  let stack = store.removeKey(selector)
  if stack.len > 0:
    result = stack[^1]

proc pushMethodStack*[Method](
    store: var SelectorMethodStore[Method], selector: SigilName, fn: Method
): int {.gcsafe, raises: [].} =
  store.addValue(selector, fn)

proc popMethodStack*[Method](
    store: var SelectorMethodStore[Method], selector: SigilName, depth: int
): bool {.gcsafe, raises: [].} =
  store.popValueStack(selector, depth)
