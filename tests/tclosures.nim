import sigils/signals
import sigils/slots
import sigils/core
import sigils/closures

import std/sugar

type
  Counter* = ref object of Agent
    value: int
    avg: int

  Originator* = ref object of Agent

proc valueChanged*(tp: Counter, val: int) {.signal.}

proc setValue*(self: Counter, value: int) {.slot.} =
  echo "setValue! ", value
  if self.value != value:
    self.value = value
    emit self.valueChanged(value)

import unittest

suite "agent closure slots":

  test "callback manual creation":
    type
      ClosureRunner[T] = ref object of Agent
        rawEnv: pointer
        rawProc: pointer
        
    proc callClosure[T](self: ClosureRunner[T], value: int) {.slot.} =
      echo "calling closure"
      if self.rawEnv.isNil():
        let c2 = cast[T](self.rawProc)
        c2(value)
      else:
        let c3 = cast[proc (a: int, env: pointer) {.nimcall.}](self.rawProc)
        c3(value, self.rawEnv)

    var
      a {.used.} = Counter.new()
      base = 100

    let
      c1: proc (a: int) =
        proc (a: int) = 
          base = a
      e = c1.rawEnv()
      p = c1.rawProc()
      cc = ClosureRunner[proc (a: int)](rawEnv: e, rawProc: p)
    connect(a, valueChanged, cc, ClosureRunner[proc (a: int) {.nimcall.}].callClosure)

    a.setValue(42)

    check a.value == 42
    check base == 42

  test "callback creation":

    var
      a = Counter.new()
      base = 100

    let
      cc3 = connectTo(a, valueChanged) do (val: int):
          base = val
    
    check not compiles(
      connectTo(a, valueChanged) do (val: float):
          base = val
    )

    echo "cc3: Type: ", $typeof(cc3)
    emit a.valueChanged(42)
    check base == 42
