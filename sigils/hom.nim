## Synchronous higher-order sends to collections of dynamic agents.
import results
import selectors

export results.Opt, results.some, results.none, results.get, results.isSome,
  results.isNone, results.`==`

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
    var matches: bool
    if receiver.performLocal(predicate, args, matches) and matches:
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
