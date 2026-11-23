## Collection searches and higher-order sends to dynamic agents.
import std/macros
import results
import private/selectorcalls
import selectors

export results.Opt, results.some, results.none, results.get, results.isSome,
  results.isNone, results.`==`

iterator snapshotItems[T](
    receivers: openArray[T], reverse: static bool = false
): T =
  let members = @receivers
  for offset in 0 ..< members.len:
    let index = when reverse: members.high - offset else: offset
    yield members[index]

template firstMatching(T: typedesc, receivers, predicate: untyped): untyped =
  block:
    let matches = predicate
    var found: Opt[T]
    for receiver in receivers:
      if matches(receiver):
        found = Opt.some(receiver)
        break
    found

template findFirst*[T](
    receivers: iterable[T], predicate: proc(receiver: T): bool {.closure.}
): Opt[T] =
  ## Return the first matching item yielded by an iterator, or none.
  firstMatching(T, receivers, predicate)

proc findFirst*[T](
    receivers: openArray[T], predicate: proc(receiver: T): bool {.closure.}
): Opt[T] =
  ## Return the first match, or none. Snapshot membership before testing.
  firstMatching(T, snapshotItems(receivers), predicate)

iterator depthFirst*[T](
    root: T, childrenOf: proc(node: T): seq[T] {.closure.},
    reverse: static bool = false
): T {.inline.} =
  ## Yield nodes in depth-first pre-order, or its exact reverse.
  ## In forward order, read a node's children when iteration resumes.
  ## Skip nil ref nodes. The child relation must be acyclic.
  var pending = @[(node: root, expanded: false)]
  while pending.len > 0:
    let (node, expanded) = pending.pop()
    when T is ref:
      if node.isNil:
        continue
    when reverse:
      if expanded:
        yield node
        continue
      pending.add (node, true)
    else:
      yield node
    let children = childrenOf(node)
    for offset in 0 ..< children.len:
      let index = when reverse: offset else: children.high - offset
      pending.add (children[index], false)

proc findFirst*[T](
    root: T, childrenOf: proc(node: T): seq[T] {.closure.},
    predicate: proc(node: T): bool {.closure.}
): Opt[T] =
  ## Search a tree in depth-first pre-order. Return none when no node matches.
  firstMatching(T, root.depthFirst(childrenOf), predicate)

proc findLast*[T](
    receivers: openArray[T], predicate: proc(receiver: T): bool {.closure.}
): Opt[T] =
  ## Search from the end and return the first match, or none.
  ## Snapshot membership before testing.
  firstMatching(T, snapshotItems(receivers, reverse = true), predicate)

proc findLast*[T](
    root: T, childrenOf: proc(node: T): seq[T] {.closure.},
    predicate: proc(node: T): bool {.closure.}
): Opt[T] =
  ## Search a tree in reverse pre-order. Return none when no node matches.
  firstMatching(T, root.depthFirst(childrenOf, reverse = true), predicate)

proc matchesLocal[A, R](
    receiver: DynamicAgent, message: Selector[A, R], args: A,
    predicate: proc(value: R): bool {.closure.}
): bool =
  var value: R
  receiver.performLocal(message, args, value) and predicate(value)

template findMatchingReply(T: typedesc, receivers, message, args,
    predicate: untyped): untyped =
  block:
    let
      selector = message
      payload = args
      matches = predicate
    firstMatching(T, receivers, proc(receiver: T): bool =
      receiver.matchesLocal(selector, payload, matches)
    )

template findFirst*[T: DynamicAgent, A, R](
    receivers: iterable[T], message: Selector[A, R], args: A,
    predicate: proc(value: R): bool {.closure.}
): Opt[T] =
  ## Find the first yielded receiver whose handled local reply passes the test.
  findMatchingReply(T, receivers, message, args, predicate)

proc findFirst*[T: DynamicAgent, A, R](
    receivers: openArray[T], message: Selector[A, R], args: A,
    predicate: proc(value: R): bool {.closure.}
): Opt[T] =
  ## Return the first receiver whose handled local reply passes the test.
  findMatchingReply(T, snapshotItems(receivers), message, args, predicate)

proc findFirst*[T: DynamicAgent, A, R](
    root: T, childrenOf: proc(node: T): seq[T] {.closure.},
    message: Selector[A, R], args: A, predicate: proc(
        value: R): bool {.closure.}
): Opt[T] =
  ## Search a tree in depth-first pre-order for a handled reply that passes the test.
  findMatchingReply(T, root.depthFirst(childrenOf), message, args, predicate)

proc findLast*[T: DynamicAgent, A, R](
    receivers: openArray[T], message: Selector[A, R], args: A,
    predicate: proc(value: R): bool {.closure.}
): Opt[T] =
  ## Search from the end for a receiver whose handled local reply passes the test.
  findMatchingReply(T, snapshotItems(receivers, reverse = true), message, args,
    predicate)

proc findLast*[T: DynamicAgent, A, R](
    root: T, childrenOf: proc(node: T): seq[T] {.closure.},
    message: Selector[A, R], args: A, predicate: proc(
        value: R): bool {.closure.}
): Opt[T] =
  ## Search a tree in reverse pre-order for a handled reply that passes the test.
  findMatchingReply(T, root.depthFirst(childrenOf, reverse = true), message, args,
    predicate)

proc isTrue(value: bool): bool = value

template findFirst*[T: DynamicAgent, A](
    receivers: iterable[T], predicate: Selector[A, bool], args: A
): Opt[T] =
  ## Find the first yielded receiver whose local predicate answers true.
  findMatchingReply(T, receivers, predicate, args, isTrue)

proc findFirst*[T: DynamicAgent, A](
    receivers: openArray[T], predicate: Selector[A, bool], args: A
): Opt[T] =
  ## Return the first receiver whose local predicate answers true, or none.
  receivers.findFirst(predicate, args, isTrue)

proc findFirst*[T: DynamicAgent, A](
    root: T, childrenOf: proc(node: T): seq[T] {.closure.},
    predicate: Selector[A, bool], args: A
): Opt[T] =
  ## Search a tree in depth-first pre-order for a true local predicate reply.
  root.findFirst(childrenOf, predicate, args, isTrue)

proc findLast*[T: DynamicAgent, A](
    receivers: openArray[T], predicate: Selector[A, bool], args: A
): Opt[T] =
  ## Search from the end for a receiver whose local predicate answers true.
  ## Return none if there is no match.
  receivers.findLast(predicate, args, isTrue)

proc findLast*[T: DynamicAgent, A](
    root: T, childrenOf: proc(node: T): seq[T] {.closure.},
    predicate: Selector[A, bool], args: A
): Opt[T] =
  ## Search a tree in reverse pre-order for a true local predicate reply.
  root.findLast(childrenOf, predicate, args, isTrue)

proc replyLocal[A, R](
    receiver: DynamicAgent, message: Selector[A, R], args: A
): Opt[R] =
  var value: R
  if receiver.performLocal(message, args, value):
    result = Opt.some(value)

template collectReplies[A, R](
    receivers: untyped, message: Selector[A, R], args: A, capacity: int
): seq[Opt[R]] =
  block:
    let
      selector = message
      payload = args
    var replies = newSeqOfCap[Opt[R]](capacity)
    for receiver in receivers:
      replies.add receiver.replyLocal(selector, payload)
    replies

template collect*[T: DynamicAgent, A, R](
    receivers: iterable[T], message: Selector[A, R], args: A
): seq[Opt[R]] =
  ## Collect a local reply for every receiver yielded by an iterator.
  ## Unhandled sends produce none.
  collectReplies(receivers, message, args, 0)

proc collect*[T: DynamicAgent, A, R](
    receivers: openArray[T], message: Selector[A, R], args: A
): seq[Opt[R]] =
  ## Send locally to each receiver and retain an entry for every reply.
  ## An unhandled send produces none, including for a nil receiver.
  ## Membership is snapshotted before the first synchronous send.
  collectReplies(snapshotItems(receivers), message, args, receivers.len)

template selectMatchingReplies(T: typedesc, receivers, message, args,
    predicate: untyped): untyped =
  block:
    let
      selector = message
      payload = args
      matches = predicate
    var selected: seq[T]
    for receiver in receivers:
      if receiver.matchesLocal(selector, payload, matches):
        selected.add receiver
    selected

template select*[T: DynamicAgent, A, R](
    receivers: iterable[T], message: Selector[A, R], args: A,
    predicate: proc(value: R): bool {.closure.}
): seq[T] =
  ## Keep yielded receivers whose handled local reply passes the test.
  selectMatchingReplies(T, receivers, message, args, predicate)

proc select*[T: DynamicAgent, A, R](
    receivers: openArray[T], message: Selector[A, R], args: A,
    predicate: proc(value: R): bool {.closure.}
): seq[T] =
  ## Keep receivers whose handled local reply passes the test.
  ## Membership is snapshotted before dispatch.
  selectMatchingReplies(T, snapshotItems(receivers), message, args, predicate)

template select*[T: DynamicAgent, A](
    receivers: iterable[T], predicate: Selector[A, bool], args: A
): seq[T] =
  ## Keep yielded receivers whose local predicate answers true.
  selectMatchingReplies(T, receivers, predicate, args, isTrue)

proc select*[T: DynamicAgent, A](
    receivers: openArray[T], predicate: Selector[A, bool], args: A
): seq[T] =
  ## Keep receivers whose local predicate send returns true.
  ## Unhandled sends are omitted. Membership is snapshotted before dispatch.
  receivers.select(predicate, args, isTrue)

proc sendEach*[T: DynamicAgent, A](
    receivers: openArray[T], message: Selector[A, tuple[]], args: A
): seq[bool] {.discardable.} =
  ## Send a command locally to every receiver and return the handled flags.
  ## Membership is snapshotted before dispatch.
  result = newSeqOfCap[bool](receivers.len)
  for receiver in snapshotItems(receivers):
    result.add receiver.sendLocalIfHandled(message, args)

proc sendEach*[A](
    message: Selector[A, tuple[]], args: A, receivers: varargs[DynamicAgent]
): seq[bool] {.discardable.} =
  ## Send a command locally to the listed receivers and return the handled flags.
  sendEach(receivers, message, args)

proc collectEach*[T: DynamicAgent, A, R](
    receivers: openArray[T], message: Selector[A, R], args: openArray[A]
): seq[Opt[R]] =
  ## Send locally to each receiver with its corresponding argument.
  ## Unequal lengths raise ValueError before any sends take place.
  if receivers.len != args.len:
    raise newException(ValueError, "one argument per receiver required")
  let
    members = @receivers
    arguments = @args
  result = newSeqOfCap[Opt[R]](members.len)
  for index, receiver in members:
    result.add receiver.replyLocal(message, arguments[index])

proc collectEach*[A, R](
    receiver: DynamicAgent, message: Selector[A, R], args: openArray[A]
): seq[Opt[R]] =
  ## Send every argument locally to the same receiver. Snapshot arguments before dispatch.
  result = newSeqOfCap[Opt[R]](args.len)
  for argument in snapshotItems(args):
    result.add receiver.replyLocal(message, argument)

proc captureSelectorCall(message: NimNode): NimNode =
  if message.kind notin {nnkCall, nnkCommand}:
    error("expected a call to a declared selector", message)
  result = newCall(message[0], newCall(bindSym"SelectorCallCapture"))
  for index in 1 ..< message.len:
    result.add message[index]

proc collectionSend(operation, receivers, message: NimNode,
    predicate: NimNode = nil): NimNode =
  let captured = captureSelectorCall(message)
  let binding = genSym(nskLet, "selectorCall")
  let send = newCall(operation, receivers, newDotExpr(binding, ident"message"),
    newDotExpr(binding, ident"args"))
  if not predicate.isNil:
    send.add predicate
  result = quote do:
    block:
      let `binding` = `captured`
      `send`

macro collectSend*(receivers, message: untyped): untyped =
  ## Collect local replies to a declared selector written in call form.
  collectionSend(bindSym"collect", receivers, message)

macro sendEachTo*(receivers, message: untyped): untyped =
  ## Send a command written in call form to a collection and return the handled flags.
  collectionSend(bindSym"sendEach", receivers, message)

macro selectSend*(receivers, message: untyped): untyped =
  ## Keep receivers whose Boolean selector call answers true.
  collectionSend(bindSym"select", receivers, message)

macro selectSend*(receivers, message, predicate: untyped): untyped =
  ## Keep receivers whose selector reply passes the predicate.
  collectionSend(bindSym"select", receivers, message, predicate)

proc selectorReplyPredicate[R: DynamicAgent, A, B](
    _: Selector[A, R], message: Selector[B, bool], args: B
): proc(receiver: R): bool {.closure.} =
  result = proc(receiver: R): bool =
    receiver.matchesLocal(message, args, isTrue)

macro selectWhere*(receivers, projection, predicate: untyped): untyped =
  ## Keep receivers whose projected agent answers true to the predicate call.
  ## Both sends are local. Nil replies and unhandled sends are skipped.
  let
    projectionCall = captureSelectorCall(projection)
    predicateCall = captureSelectorCall(predicate)
  result = quote do:
    block:
      let
        attribute = `projectionCall`
        test = `predicateCall`
      select(`receivers`, attribute.message, attribute.args,
        selectorReplyPredicate(attribute.message, test.message, test.args))

proc sendEachLocal*[T: DynamicAgent, A](
    receivers: openArray[T], message: Selector[A, tuple[]], args: A
): seq[bool] {.inline, deprecated: "use sendEach".} =
  sendEach(receivers, message, args)

proc collectEachLocal*[T: DynamicAgent, A, R](
    receivers: openArray[T], message: Selector[A, R], args: openArray[A]
): seq[Opt[R]] {.inline, deprecated: "use collectEach".} =
  collectEach(receivers, message, args)

proc collectEachLocal*[A, R](
    receiver: DynamicAgent, message: Selector[A, R], args: openArray[A]
): seq[Opt[R]] {.inline, deprecated: "use collectEach".} =
  collectEach(receiver, message, args)
