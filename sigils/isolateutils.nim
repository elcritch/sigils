import std/strformat
import std/isolation
import threading/smartptrs

import weakrefs
export isolation

# template checkThreadSafety(field: object, parent: typed): static bool =
#   true
# template checkThreadSafety[T](field: Isolated[T], parent: typed): static bool =
#   true
# template checkThreadSafety(field: ref, parent: typed): static bool =
#   false
# template checkThreadSafety[T](field: T, parent: typed): static bool =
#   true

proc checkThreadSafety[T, V](field: T, parent: V) =
  when T is ref:
    if not checkThreadSafety(v, sig):
        {.
          error:
            "Signal type with ref's aren't thread safe! Signal type: " & $(typeof(sig)) &
            ". Use `Isolate[" & $(typeof(v)) & "]` to use it."
        .}
  elif T is tuple or T is object:
    static:
      echo "checkThreadSafety: object: ", $(T)
    for n, v in field.fieldPairs():
      checkThreadSafety(v, parent)
  else:
    static:
      echo "checkThreadSafety: skip: ", $T
    discard

template checkSignalThreadSafety*(sig: typed) =
  checkThreadSafety(sig, sig)

type IsolationError* = object of CatchableError

import std/macros

import std/private/syslocks
proc verifyUniqueSkip(tp: typedesc[SysLock]) = discard

proc verifyUnique[T, V](field: T, parent: V) =
  # mixin verifyUnique
  when T is ref:
    # static:
    #   echo "verifyUnique: ref: ", $T
    if not field.isNil:
      if not field.isUniqueRef():
        echo "verifyUnique: count: ", field.unsafeGcCount(), " ", field.repr
        raise newException(IsolationError, &"reference not unique! Cannot safely isolate {$typeof(field)} parent: {$typeof(parent)} ")
      for v in field[].fields():
        verifyUnique(v, parent)
  elif T is tuple or T is object:
    when compiles(verifyUniqueSkip(T)):
      # static:
      #   echo "verifyUnique: skipping type: ", $T
      discard
    else:
      # static:
      #   echo "verifyUnique: object: ", $(T)
      for n, v in field.fieldPairs():
        # static:
        #   echo "verifyUnique: field: ", n, " tp: ", typeof(v)
        verifyUnique(v, parent)
  else:
    # static:
    #   echo "verifyUnique: skip: ", $T
    discard


# proc isolateRuntime*[T](item: sink T): Isolated[T] {.raises: [IsolationError].} =
proc isolateRuntime*[T](item: sink T): Isolated[T] =
  ## Isolates a ref type or type with ref's and ensure that
  ## each ref is unique. This allows safely isolating it.
  when T is ref:
    echo "isolateRuntime:call: ", item.unsafeGcCount()
  when compiles(isolate(item)):
    # static:
    #   echo "\n### IsolateRuntime: compile isolate: ", $T
    result = isolate(item)
  else:
    # static:
    #   echo "\n### IsolateRuntime: runtime isolate: ", $T
    verifyUnique(item, item)
    result = unsafeIsolate(item)

proc isolateRuntime*[T](item: SharedPtr[T]): Isolated[SharedPtr[T]] =
  var item = item
  unsafeIsolate(move item)
