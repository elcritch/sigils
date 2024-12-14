import std/isolation
export isolation

template checkThreadSafety(field: object, parent: typed) =
  discard

template checkThreadSafety[T](field: Isolated[T], parent: typed) =
  discard

template checkThreadSafety(field: ref, parent: typed) =
  {.
    error:
      "Signal type with ref's aren't thread safe! Signal type: " & $(typeof(parent)) &
      ". Use `Isolate[" & $(typeof(field)) & "]` to use it."
  .}

template checkThreadSafety[T](field: T, parent: typed) =
  discard

template checkSignalThreadSafety(sig: typed) =
  for n, v in sig.fieldPairs():
    checkThreadSafety(v, sig)

type IsolateError* = object of CatchableError

template verifyUnique[T](field: T) =
  discard

template verifyUnique(field: ref) =
  if not field.isUniqueRef():
    raise newException(IsolateError, "reference not unique! Cannot safely isolate it")
  for v in field[].fields():
    verifyUnique(v)

template verifyUnique[T: tuple | object](field: T) =
  for n, v in field.fieldPairs():
    checkThreadSafety(v, sig)

proc tryIsolate*[T](field: T): Isolated[T] {.raises: [IsolateError].} =
  ## Isolates a ref type or type with ref's and ensure that
  ## each ref is unique. This allows safely isolating it.
  verifyUnique(field)
