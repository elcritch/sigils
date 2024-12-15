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

template checkSignalThreadSafety*(sig: typed) =
  for n, v in sig.fieldPairs():
    checkThreadSafety(v, sig)

type IsolationError* = object of CatchableError

template verifyUnique[T](field: T) =
  static:
    echo "verifyUnique: skip"
  discard

template verifyUnique(field: ref, parent: typed) =
  static:
    echo "verifyUnique: ref"
  if not field.isUniqueRef():
    raise newException(IsolationError, "reference not unique! Cannot safely isolate it")
  for v in field[].fields():
    verifyUnique(v)

template verifyUnique[T: tuple | object](field: T, parent: typed) =
  static:
    echo "verifyUnique: object: ", $(T)
  for n, v in field.fieldPairs():
    checkThreadSafety(v, parent)

proc isolateRuntime*[T](item: T): Isolated[T] {.raises: [IsolationError].} =
  ## Isolates a ref type or type with ref's and ensure that
  ## each ref is unique. This allows safely isolating it.
  when compiles(isolate(item)):
    echo "compile isolate: ", item.repr
    result = isolate(item)
  else:
    echo "runtime isolate: ", item.repr
    verifyUnique(item, item)
    result = unsafeIsolate(item)
