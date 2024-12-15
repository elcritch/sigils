import std/isolation
export isolation

template checkThreadSafety(field: object, parent: typed): static bool =
  true

template checkThreadSafety[T](field: Isolated[T], parent: typed): static bool =
  true

template checkThreadSafety(field: ref, parent: typed): static bool =
  false

template checkThreadSafety[T](field: T, parent: typed): static bool =
  true

template checkSignalThreadSafety*(sig: typed) =
  for n, v in sig.fieldPairs():
    static:
      if not checkThreadSafety(v, sig):
        {.
          error:
            "Signal type with ref's aren't thread safe! Signal type: " & $(typeof(parent)) &
            ". Use `Isolate[" & $(typeof(field)) & "]` to use it."
        .}

type IsolationError* = object of CatchableError

template verifyUnique[T](field: T) =
  static:
    echo "verifyUnique: skip: ", $T
  discard

template verifyUnique(field: ref, parent: typed) =
  static:
    echo "verifyUnique: ref: ", $T
  if not field.isUniqueRef():
    raise newException(IsolationError, "reference not unique! Cannot safely isolate it")
  for v in field[].fields():
    verifyUnique(v)


template verifyUnique[T: tuple | object](field: T, parent: typed) =
  static:
    echo "verifyUnique: object: ", $(T)
  for n, v in field.fieldPairs():
    when checkThreadSafety(v, parent):
      static:
        echo "verifyUnique: compile time safe: ", $(typeof(v))
    else:
      static:
        echo "verifyUnique: not safe: ", $(typeof(v))

proc isolateRuntime*[T](item: T): Isolated[T] {.raises: [IsolationError].} =
  ## Isolates a ref type or type with ref's and ensure that
  ## each ref is unique. This allows safely isolating it.
  when compiles(isolate(item)):
    static:
      echo "\nIsolateRuntime: compile isolate: ", $T
    result = isolate(item)
  else:
    static:
      echo "\nIsolateRuntime: runtime isolate: ", $T
    verifyUnique(item, item)
    result = unsafeIsolate(item)
