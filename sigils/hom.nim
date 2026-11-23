## Collection searches and higher-order sends to dynamic agents.
import std/macros
import results
import private/selectorcalls
import selectors

export results.Opt, results.some, results.none, results.get, results.isSome,
  results.isNone, results.`==`

type ClosureIterator[T] = iterator(): T {.closure.}

type ReplyMatch*[T, R] = object
  ## The receiver and accepted reply from a first-reply search.
  receiver*: T
  reply*: R

iterator remainingItems[T](receivers: ClosureIterator[T]): T =
  if not receivers.isNil:
    for receiver in receivers():
      yield receiver

iterator follow*[T: ref](
    first: T, next: proc(current: T): T {.closure.}
): T =
  ## Yield each node, asking for its successor after the yield.
  ## A nil successor ends traversal. The links must be acyclic.
  var current = first
  while not current.isNil:
    yield current
    current = next(current)

iterator responderChain*(first: DynamicAgent): DynamicAgent =
  ## Yield the receiver and follow its current next responder after each yield.
  ## The responder chain must be acyclic.
  for receiver in follow(first, nextResponder):
    yield receiver

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

proc findFirst*[T](
    receivers: ClosureIterator[T],
    predicate: proc(receiver: T): bool {.closure.}
): Opt[T] =
  ## Find the first match and leave the iterator positioned after it.
  firstMatching(T, remainingItems(receivers), predicate)

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
    receivers: ClosureIterator[T], message: Selector[A, R], args: A,
    predicate: proc(value: R): bool {.closure.}
): Opt[T] =
  ## Stop at the first receiver whose handled local reply passes the test.
  findMatchingReply(T, remainingItems(receivers), message, args, predicate)

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
    receivers: ClosureIterator[T], predicate: Selector[A, bool], args: A
): Opt[T] =
  ## Stop at the first receiver whose local predicate answers true.
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

template firstReply(T, R: typedesc, receivers, getReply,
    predicate: untyped): untyped =
  block:
    let
      query = getReply
      accepts = predicate
    var found: Opt[ReplyMatch[T, R]]
    for receiver in receivers:
      let reply = query(receiver)
      if reply.isSome and accepts(reply.get()):
        found = Opt.some(ReplyMatch[T, R](receiver: receiver, reply: reply.get()))
        break
    found

template findFirstReply*[T, R](
    receivers: iterable[T], query: proc(receiver: T): R {.closure.},
    predicate: typed
): Opt[ReplyMatch[T, R]] =
  ## Return the first receiver and callback reply accepted by the predicate.
  block:
    let callback = query
    firstReply(T, R, receivers, proc(receiver: T): Opt[R] = Opt.some(callback(
        receiver)),
      predicate)

proc findFirstReply*[T, R](
    receivers: openArray[T], query: proc(receiver: T): R {.closure.},
    predicate: proc(reply: R): bool {.closure.}
): Opt[ReplyMatch[T, R]] =
  ## Snapshot membership before calling the query.
  firstReply(T, R, snapshotItems(receivers),
    proc(receiver: T): Opt[R] = Opt.some(query(receiver)), predicate)

proc findFirstReply*[T, R](
    receivers: ClosureIterator[T], query: proc(receiver: T): R {.closure.},
    predicate: proc(reply: R): bool {.closure.}
): Opt[ReplyMatch[T, R]] =
  ## Stop at a match and leave the iterator ready to resume.
  firstReply(T, R, remainingItems(receivers),
    proc(receiver: T): Opt[R] = Opt.some(query(receiver)), predicate)

template findFirstReply*[T: DynamicAgent, A, R](
    receivers: iterable[T], message: Selector[A, R], args: A,
    predicate: typed
): Opt[ReplyMatch[T, R]] =
  ## Return the first accepted local selector reply with its receiver.
  block:
    let selector = message
    let payload = args
    firstReply(T, R, receivers,
      proc(receiver: T): Opt[R] = receiver.replyLocal(selector, payload), predicate)

proc findFirstReply*[T: DynamicAgent, A, R](
    receivers: openArray[T], message: Selector[A, R], args: A,
    predicate: proc(reply: R): bool {.closure.}
): Opt[ReplyMatch[T, R]] =
  ## Snapshot membership and return the first accepted local reply.
  firstReply(T, R, snapshotItems(receivers),
    proc(receiver: T): Opt[R] = receiver.replyLocal(message, args), predicate)

proc findFirstReply*[T: DynamicAgent, A, R](
    receivers: ClosureIterator[T], message: Selector[A, R], args: A,
    predicate: proc(reply: R): bool {.closure.}
): Opt[ReplyMatch[T, R]] =
  ## Stop at the first accepted local reply and leave the iterator ready to resume.
  firstReply(T, R, remainingItems(receivers),
    proc(receiver: T): Opt[R] = receiver.replyLocal(message, args), predicate)

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

proc collect*[T: DynamicAgent, A, R](
    receivers: ClosureIterator[T], message: Selector[A, R], args: A
): seq[Opt[R]] =
  ## Consume the iterator and collect a local reply for every remaining receiver.
  collectReplies(remainingItems(receivers), message, args, 0)

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

proc select*[T: DynamicAgent, A, R](
    receivers: ClosureIterator[T], message: Selector[A, R], args: A,
    predicate: proc(value: R): bool {.closure.}
): seq[T] =
  ## Consume the iterator, keeping receivers whose handled local replies pass the test.
  selectMatchingReplies(T, remainingItems(receivers), message, args, predicate)

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

proc select*[T: DynamicAgent, A](
    receivers: ClosureIterator[T], predicate: Selector[A, bool], args: A
): seq[T] =
  ## Consume the iterator, keeping receivers whose local predicate answers true.
  receivers.select(predicate, args, isTrue)

template sendCommands[A](
    receivers: untyped, message: Selector[A, tuple[]], args: A, capacity: int
): seq[bool] =
  block:
    var handled = newSeqOfCap[bool](capacity)
    for receiver in receivers:
      handled.add receiver.sendLocalIfHandled(message, args)
    handled

proc sendEach*[T: DynamicAgent, A](
    receivers: openArray[T], message: Selector[A, tuple[]], args: A
): seq[bool] {.discardable.} =
  ## Send a command locally to every receiver and return the handled flags.
  ## Membership is snapshotted before dispatch.
  sendCommands(snapshotItems(receivers), message, args, receivers.len)

proc sendEach*[T: DynamicAgent, A](
    receivers: ClosureIterator[T], message: Selector[A, tuple[]], args: A
): seq[bool] {.discardable.} =
  ## Consume the iterator, sending a local command and reporting handling for each receiver.
  sendCommands(remainingItems(receivers), message, args, 0)

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

macro findFirstSend*(receivers, message, predicate: untyped): untyped =
  ## Find the first accepted local reply to a selector written in call form.
  collectionSend(bindSym"findFirstReply", receivers, message, predicate)

proc sendEachCaptured[T: DynamicAgent, A](
    receivers: openArray[T],
    command: tuple[message: Selector[A, tuple[]], args: A]
): seq[bool] {.inline, discardable.} =
  sendEach(receivers, command.message, command.args)

proc sendEachCaptured[T: DynamicAgent, A](
    receivers: ClosureIterator[T],
    command: tuple[message: Selector[A, tuple[]], args: A]
): seq[bool] {.inline, discardable.} =
  sendEach(receivers, command.message, command.args)

macro sendEachTo*(receivers, message: untyped): untyped =
  ## Send a command written in call form to a collection and return the handled flags.
  ## Evaluate the receiver expression before the selector arguments.
  newCall(bindSym"sendEachCaptured", receivers, captureSelectorCall(message))

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
