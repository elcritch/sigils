import std/strformat
import std/isolation
import threading/smartptrs

import weakrefs
export isolation

proc checkThreadSafety[T, V](field: T, parent: V) =
  when T is ref:
    if not checkThreadSafety(v, sig):
      {.
        error:
          "Signal type with ref's aren't thread safe! Signal type: " & $(typeof(
              sig)) &
          ". Use `Isolate[" & $(typeof(v)) & "]` to use it."
      .}
  elif T is tuple or T is object:
    {.hint: "checkThreadSafety: object: " & $(T).}
    for n, v in field.fieldPairs():
      checkThreadSafety(v, parent)
  else:
    {.hint: "checkThreadSafety: skip: " & $(T).}

template checkSignalThreadSafety*(sig: typed) =
  checkThreadSafety(sig, sig)

type IsolationError* = object of CatchableError

import std/macros

import std/private/syslocks
proc verifyUniqueSkip(tp: typedesc[SysLock]) =
  discard

proc verifyUnique[T, V](field: T, parent: V) =
  when T is ref:
    if not field.isNil:
      if not field.isUniqueRef():
        raise newException(
          IsolationError,
          &"reference not unique! Cannot safely isolate {$typeof(field)} parent: {$typeof(parent)} ",
        )
      for v in field[].fields():
        verifyUnique(v, parent)
  elif T is tuple or T is object:
    when compiles(verifyUniqueSkip(T)):
      discard
    else:
      for n, v in field.fieldPairs():
        verifyUnique(v, parent)
  else:
    discard

proc isolateRuntime*[T](item: sink T): Isolated[T] {.raises: [
    IsolationError].} =
  ## Isolates a ref type or type with ref's and ensure that
  ## each ref is unique. This allows safely isolating it.
  when compiles(isolate(item)):
    result = isolate(item)
  else:
    verifyUnique(item, item)
    result = unsafeIsolate(item)

proc isolateRuntime*[T](item: SharedPtr[T]): Isolated[SharedPtr[T]] =
  var item = item
  unsafeIsolate(move item)
