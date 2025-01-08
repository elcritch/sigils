
import signals
import slots
import agents
import std/macros

export signals, slots, agents

type
  ClosureAgent*[T] = ref object of Agent
    rawEnv: pointer
    rawProc: pointer

macro callWithEnv(fn, args, env: typed): NimNode =
  discard

proc callClosure[T](self: ClosureAgent[T], value: int) {.slot.} =
  echo "calling closure"
  if self.rawEnv.isNil():
    let c2 = cast[T](self.rawProc)
    c2(value)
  else:
    let c3 = cast[proc (a: int, env: pointer) {.nimcall.}](self.rawProc)
    c3(value, self.rawEnv)

# macro mkClosure(fn: typed) =
#   mkParamsType()

proc newClosureAgent*[T: proc {.closure.}](fn: T): ClosureAgent[T] =
  let
    e = fn.rawEnv()
    p = fn.rawProc()
  result = ClosureAgent[T](rawEnv: e, rawProc: p)

template connectTo*(
    a: Agent,
    signal: typed,
    blk: typed
): auto =
  var signalType {.used, inject.}: typeof(SignalTypes.`signal`(typeof(a)))

  static:
    echo "CALL:: signalType: ", $typeof(SignalTypes.`signal`(typeof(a)))

  ClosureAgent[typeof(signalType)]()
