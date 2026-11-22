## Collection searches and higher-order sends to dynamic agents.
import results
import selectors

export results.Opt, results.some, results.none, results.get, results.isSome,
  results.isNone, results.`==`

proc findFirst*[T](
    receivers: openArray[T], predicate: proc(receiver: T): bool {.closure.}
): Opt[T] =
  ## Return the first match, or none. Snapshot membership before testing.
  let members = @receivers
  for receiver in members:
    if predicate(receiver):
      return Opt.some(receiver)

proc findFirst*[T](
    root: T, childrenOf: proc(node: T): seq[T] {.closure.},
    predicate: proc(node: T): bool {.closure.}
): Opt[T] =
  ## Search a tree in depth-first pre-order, including the root.
  ## Skip nil ref nodes. Read each node's children only after its test fails.
  ## The child relation must be acyclic. Return none when no node matches.
  var pending = @[root]
  while pending.len > 0:
    let node = pending.pop()
    when T is ref:
      if node.isNil:
        continue
    if predicate(node):
      return Opt.some(node)
    let children = childrenOf(node)
    for index in countdown(children.high, 0):
      pending.add children[index]

proc findLast*[T](
    receivers: openArray[T], predicate: proc(receiver: T): bool {.closure.}
): Opt[T] =
  ## Search from the end and return the first match, or none.
  ## Snapshot membership before testing.
  let members = @receivers
  for index in countdown(members.high, 0):
    let receiver = members[index]
    if predicate(receiver):
      return Opt.some(receiver)

proc findAny*[T](
    receivers: openArray[T], predicate: proc(receiver: T): bool {.closure.}
): Opt[T] =
  ## Return a match, or none. The order of predicate calls is unspecified.
  receivers.findFirst(predicate)

proc matchesLocal[A, R](
    receiver: DynamicAgent, message: Selector[A, R], args: A,
    predicate: proc(value: R): bool {.closure.}
): bool =
  var value: R
  receiver.performLocal(message, args, value) and predicate(value)

proc findFirst*[T: DynamicAgent, A, R](
    receivers: openArray[T], message: Selector[A, R], args: A,
    predicate: proc(value: R): bool {.closure.}
): Opt[T] =
  ## Return the first receiver whose handled local reply passes the test.
  receivers.findFirst(proc(receiver: T): bool =
    receiver.matchesLocal(message, args, predicate)
  )

proc findFirst*[T: DynamicAgent, A, R](
    root: T, childrenOf: proc(node: T): seq[T] {.closure.},
    message: Selector[A, R], args: A, predicate: proc(
        value: R): bool {.closure.}
): Opt[T] =
  ## Search a tree in depth-first pre-order for a handled reply that passes the test.
  root.findFirst(childrenOf, proc(node: T): bool =
    node.matchesLocal(message, args, predicate)
  )

proc findLast*[T: DynamicAgent, A, R](
    receivers: openArray[T], message: Selector[A, R], args: A,
    predicate: proc(value: R): bool {.closure.}
): Opt[T] =
  ## Search from the end for a receiver whose handled local reply passes the test.
  receivers.findLast(proc(receiver: T): bool =
    receiver.matchesLocal(message, args, predicate)
  )

proc findAny*[T: DynamicAgent, A, R](
    receivers: openArray[T], message: Selector[A, R], args: A,
    predicate: proc(value: R): bool {.closure.}
): Opt[T] =
  ## Return a receiver whose handled local reply passes the test.
  ## The order of predicate calls and the choice of match are unspecified.
  receivers.findFirst(message, args, predicate)

proc isTrue(value: bool): bool = value

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

proc findAny*[T: DynamicAgent, A](
    receivers: openArray[T], predicate: Selector[A, bool], args: A
): Opt[T] =
  ## Return a receiver whose local predicate answers true, or none.
  ## The order of predicate calls and the choice of match are unspecified.
  receivers.findFirst(predicate, args)

proc collectLocal*[T: DynamicAgent, A, R](
    receivers: openArray[T], message: Selector[A, R], args: A
): seq[Opt[R]] =
  ## Send locally to each receiver and retain an entry for every reply.
  ## An unhandled send produces none, including for a nil receiver.
  ## Membership is snapshotted before the first synchronous send.
  let members = @receivers
  result = newSeqOfCap[Opt[R]](members.len)
  for receiver in members:
    var value: R
    if receiver.performLocal(message, args, value):
      result.add Opt.some(value)
    else:
      result.add Opt.none(R)

proc selectLocal*[T: DynamicAgent, A](
    receivers: openArray[T], predicate: Selector[A, bool], args: A
): seq[T] =
  ## Keep receivers whose local predicate send returns true.
  ## Unhandled sends are omitted. Membership is snapshotted before dispatch.
  let members = @receivers
  for receiver in members:
    if receiver.matchesLocal(predicate, args, isTrue):
      result.add receiver

proc sendEachLocal*[T: DynamicAgent, A](
    receivers: openArray[T], message: Selector[A, tuple[]], args: A
): seq[bool] =
  ## Send a command locally to every receiver, reporting which handled it.
  ## Membership is snapshotted before dispatch.
  let members = @receivers
  result = newSeqOfCap[bool](members.len)
  for receiver in members:
    var value: tuple[]
    result.add receiver.performLocal(message, args, value)

proc collectEachLocal*[T: DynamicAgent, A, R](
    receivers: openArray[T], message: Selector[A, R], args: openArray[A]
): seq[Opt[R]] =
  ## Send each receiver its corresponding argument.
  ## Unequal lengths raise ValueError before any sends take place.
  if receivers.len != args.len:
    raise newException(ValueError, "one argument per receiver required")
  let
    members = @receivers
    arguments = @args
  result = newSeqOfCap[Opt[R]](members.len)
  for index, receiver in members:
    var value: R
    if receiver.performLocal(message, arguments[index], value):
      result.add Opt.some(value)
    else:
      result.add Opt.none(R)
