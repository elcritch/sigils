import sigils/reactive
import std/math

import unittest
import std/sequtils

template isNear*[T](a, b: T, eps = 1.0e-5): bool =
  let same = near(a, b, eps)
  if not same:
    checkpoint("a and b not almost equal: a: " & $a & " b: " & $b & " delta: " & $(a-b))
  same
  
  
suite "#sigil":
  test """
    Given a sigil of value 5
    When the sigil is invoked
    Then it should return the value 5
  """:
    let x = newSigil(5)
    check x{} == 5
  
  test """
    Given a sigil
    When an attempt is made to assign to the sigil's value directly
    Then it should not compile
  """:
    let x = newSigil(5)
      
    check not compiles(x{} = 4)
    check not compiles(x{} <- 4)
    
  test """
    Given a sigil of value 5
    When an attempt is made to assign to the sigil using arrow syntax to 4
    Then it should change the value to 4 
  """:
    let x = newSigil(5)
  
    x <- 4

    check x{} == 4

suite "#computed sigil":
  test """
    Given a computed sigil
    When an attempt is made to assign to the sigil
    Then it should not compile
  """:
    let 
      x = newSigil(5)
      y = computed[int](x{} * 2)
      
    check not compiles(y{} = 4)
    check not compiles(y{} <- 4)

  test """
    Given a sigil of value 5 and a computed that is double the sigil
    When the computed sigil is invoked
    Then it should return the value 10
  """:
    let 
      x = newSigil(5)
      y = computed[int](2*x{})

    check y{} == 10
    
  test """
  """:
    let 
      x = newSigil(5)
      y = int <== 2*x{}

    check y{} == 10
    
  test """
    Given a sigil of value 5 and a computed that is double the sigil
    When the sigils value is changed to 2 and the computed sigil is invoked
    Then it should return the value 4
  """:
    # Given
    let
      x = newSigil(5)
      y = computed[int](2 * x{})

    when defined(sigilsDebug):
      x.debugName = "X"
      y.debugName = "Y"

    check x{} == 5
    check y{} == 10

    x <- 2

    check x{} == 2
    check y{} == 4
    
  test """
    Given a sigil of and a computedNow that is double the sigil
    When the sigils value is changed
    Then it should do an additional compute
  """:
    # Given
    let
      count = new(int)
      x = newSigil(5)
      y = computedNow[int]:
        count[] += 1
        2 * x{}

    when defined(sigilsDebug):
      x.debugName = "X"
      y.debugName = "Y"

    check count[] == 1
    x <- 2
    check count[] == 2

    test """
      Given a sigil of value 5
      When there is a computedNow sigil that is not being invoked
      Then it should still perform the computation immediately
    """:
      let
        count: ref int = new(int)
        x = newSigil(5)
        y = computedNow[int]:
          count[] += 1
          2 * x{}

      when defined(sigilsDebug):
        x.debugName = "X"
        y.debugName = "Y"

      check count[] == 1
      
    test """
      Given a sigil of value 5 and a computed that is double the sigil
      When the computed sigil is invoked multiple times
      Then it should perform the compute only once
    """:
      let
        count: ref int = new(int)
        x = newSigil(5)
        y = computed[int]:
          count[] += 1
          2 * x{}

      when defined(sigilsDebug):
        x.debugName = "X"
        y.debugName = "Y"

      check count[] == 0
      discard y{}
      discard y{}
      check count[] == 1
 
  test """
    Given a computed sigil that is the sum of 2 sigils
    When either sigil is changed
    Then the computed sigil should be recomputed when the
    sigil is read
  """:
    let
      count = new(int)
      x = newSigil(1)
      y = newSigil(2)
      z = computed[int]():
        count[] += 1
        x{} + y{}
    
    check count[] == 0 # hasn't been read yet
    check z{} == 3
    check count[] == 1 # hasn't been read yet
  
    x <- 2
    check count[] == 1
    check z{} == 4
    
    y <- 3
    x <- 3
    check z{} == 6
    check count[] == 3
    
  test """
    Given a computedNow sigil that is the sum of 2 sigils
    When either sigil is changed
    Then the computed sigil should be recomputed for every change
  """:
    let
      count = new(int)
      x = newSigil(1)
      y = newSigil(2)
      z = computedNow[int]():
        count[] += 1
        x{} + y{}
    
    check count[] == 1
    check z{} == 3
  
    x <- 2
    check count[] == 2
    check z{} == 4
    
    y <- 3
    x <- 3
    check count[] == 4
    check z{} == 6
    
  test """
    Given a computed sigil that is double a computed sigil that is double a sigil
    When the sigil value changes to 4
    Then the computed sigil should be recomputed once to 16
  """:
    let 
      countB = new(int)
      countC = new(int)
      a = newSigil(1)
      b = computed[int]:
        countB[] += 1
        2 * a{}
      c = computed[int]:
        countC[] += 1
        2 * b{}

    check countB[] == 0
    check countC[] == 0

    check c{} == 4
    check countB[] == 1
    check countC[] == 1

    echo "A: ", a
    echo "B: ", b
    echo "C: ", c

    a <- 4
    
    echo "A': ", a
    echo "B': ", b
    echo "C': ", c

    check c{} == 16
    check countC[] == 2
  
  test """
    Given a computedNow sigil that is double a computed sigil that is double a sigil
    When the sigil value changes to 4
    Then the computed sigil should be recomputed once to 16
  """:
    let 
      count = new(int)
      a = newSigil(1)
      b = computedNow[int](2 * a{})
      c = computedNow[int]:
        count[] += 1
        2 * b{}

    check count[] == 1
    check c{} == 4

    a <- 4
    
    check count[] == 2
    check c{} == 16
  
  test """
    Given a computed sigil A that depends on a computed sigil B and both of them depend directly on the same sigil C
    When the sigil value of C changes
    Then the computed sigil A should be recomputed twice, once from the change of sigil C, once from the change of the computed sigil B .
  """:
    let 
      count = new(int)
      a = newSigil(1)
      b = computed[int](2 * a{})
      c = computed[int]:
        count[] += 1
        a{} + b{}
      
    check count[] == 0
    check c{} == 3
    check count[] == 1
    
    a <- 4
    
    check c{} == 12
    check count[] == 2
  
  test """
    Given a computed sigil that is double an int-sigil but is always 0 if a boolean sigil is false
    When the sigils update
    Then the computed sigil should recompute accordingly
  """:
    let x = newSigil(5)
    let y = newSigil(false)

    when defined(sigilsDebug):
      x.debugName = "X"
      y.debugName = "Y"

    let z = computed[int]():
      if y{}:
        x{} * 2
      else:
        0

    when defined(sigilsDebug):
      z.debugName = "Z"

    check x{} == 5
    check y{} == false
    check z{} == 0

    y <- true
    check y{} == true
    check z{} == 10

    x <- 2
    check x{} == 2
    check z{} == 4

    y <- false
    check y{} == false
    check z{} == 0

  test """
    Given a computed sigil of type float32 multiplying 2 float32 sigils
    When the float sigils are changed
    Then the computed sigil should update
  """:
    let x = newSigil(3.14'f32)
    let y = newSigil(2.718'f32)

    let z = computed[float32]():
      x{} * y{}

    check isNear(x{}, 3.14)
    check isNear(y{}, 2.718)
    check isNear(z{}, 8.53452, 3)

    x <- 1.0
    check isNear(x{}, 1.0)
    check isNear(y{}, 2.718)
    check isNear(z{}, 2.718, 3)

  test """
    Given a computed sigil of type float multiplying a float32 and a float64 sigil
    When the float sigils are changed
    Then the computed sigil should update
  """:
    let x = newSigil(3.14'f64)
    let y = newSigil(2.718'f32)

    let z = computed[float]():
      x{} * y{}

    echo "X: ", x{}, " Z: ", z{}
    check isNear(x{}, 3.14)
    check isNear(y{}, 2.718)
    check isNear(z{}, 8.53451979637.float, 4)

    x <- 1.0
    check isNear(x{}, 1.0)
    check isNear(y{}, 2.718)
    check isNear(z{}, 2.718)

suite "#computed sigil":
  test """
    Given a computed sigil
    When an attempt is made to assign to the sigil
    Then it should not compile
  """:
    let 
      x = newSigil(5)
      y = computed[int](x{} * 2)
      
    check not compiles(y{} = 4)
    check not compiles(y{} <- 4)

  test """
    Given a sigil of value 5 and a computed that is double the sigil
    When the computed sigil is invoked
    Then it should return the value 10
  """:
    let 
      x = newSigil(5)
      y = computed[int](2*x{})

    check y{} == 10
    
  test """
    Given a sigil of value 5 and a computed that is double the sigil
    When the sigils value is changed to 2 and the computed sigil is invoked
    Then it should return the value 4
  """:
    # Given
    let
      x = newSigil(5)
      y = computed[int](2 * x{})

    when defined(sigilsDebug):
      x.debugName = "X"
      y.debugName = "Y"

    check x{} == 5
    check y{} == 10

    x <- 2

    check x{} == 2
    check y{} == 4
    
  test """
    Given a sigil and a computed that is double the sigil
    When the sigils value is changed
    Then it should only do a compute after the computed sigil was invoked
  """:
    # Given
    let
      count = new(int)
      x = newSigil(5)
      y = computed[int]:
        count[] += 1
        2 * x{}

    when defined(sigilsDebug):
      x.debugName = "X"
      y.debugName = "Y"

    check count[] == 0
    x <- 2
    check count[] == 0
    check y{} == 4
    check count[] == 1

    test """
      Given a sigil of value 5
      When there is a computed sigil that is not being invoked
      Then it should not perform the computation
    """:
      let
        count: ref int = new(int)
        x = newSigil(5)
        y = computed[int]:
          count[] += 1
          2 * x{}

      when defined(sigilsDebug):
        x.debugName = "X"
        y.debugName = "Y"

      check count[] == 0
      
    test """
      Given a sigil of value 5 and a computed that is double the sigil
      When the computed sigil is invoked multiple times
      Then it should perform the compute only once after the first invocation
    """:
      let
        count: ref int = new(int)
        x = newSigil(5)
        y = computed[int]:
          count[] += 1
          2 * x{}

      when defined(sigilsDebug):
        x.debugName = "X"
        y.debugName = "Y"

      check count[] == 0
      discard y{}
      check count[] == 1
      discard y{}
      check count[] == 1
    
  test """
    Given a computed sigil that is the sum of 2 sigils
    When either sigil is changed
    Then the computed sigil only be recomputed each time after an invocation, not after a sigil change
  """:
    let
      count = new(int)
      x = newSigil(1)
      y = newSigil(2)
      z = computed[int]():
        count[] += 1
        x{} + y{}
    
    check count[] == 0
    check z{} == 3
    check count[] == 1
  
    x <- 2
    check count[] == 1
    check z{} == 4
    check count[] == 2
    
    y <- 3
    x <- 3
    check count[] == 2
    check z{} == 6
    check count[] == 3
    
  test """
    Given a computed sigil A that is double a computed sigil B that is double a sigil C of value 1
    When sigil A is invoked
    Then it should return 4 and also compute computed sigil B, but only once
  """:
    let 
      countA = new(int)
      countB = new(int)
      c = newSigil(1)
      b = computed[int]:
        countB[] += 1
        2 * c{}
      a = computed[int]:
        countA[] += 1
        2 * b{}
      
    check countA[] == 0
    check countB[] == 0
    
    check a{} == 4
    
    check countA[] == 1
    check countB[] == 1
    
    check b{} == 2
    check countB[] == 1

suite "#bridge sigils and agents":
  test """
    Test bridging Sigils to regular Sigil Agents. e.g. for comptability
    with Figuro where we wanna override hook in with {} when we 
    use Sigils
  """:
    type SomeAgent = ref object of Agent
      value: int

    template getInternalSigilIdent(): untyped =
      ## provide this to override the default `internalSigil`
      ## identify, for using local naming schema
      agent

    let 
      a = newSigil(2)
      b = computed[int]: 2 * a{}
      foo = SomeAgent()

    check a{} == 2
    check b{} == 4
    
    ## Bit annoying, to have to use a regular proc
    ## since the slot pragma and forward proc decl's
    ## don't seem to mix
    ## In Figuro `recompute` would just call `refresh`
    proc doDraw(obj: SomeAgent)
    proc recompute(obj: SomeAgent) {.slot.} =
      obj.doDraw()

    proc draw(agent: SomeAgent) {.slot.} =
      let value = b{}
      agent.value = value
    
    proc doDraw(obj: SomeAgent) =
      obj.draw()

    foo.draw()

    check b{} == 4
    check foo.value == 4
    b <- 5
    check b{} == 5
    check foo.value == 5

suite "#effects":
  test """
    Given a sigil effect
  """:
    var internalSigilEffectRegistry = initSigilEffectRegistry()

    let 
      count = new(int)
      x = newSigil(5)

    effect:
      count[].inc()
      echo "X is now: ", x{} * 2
 
    # check count[] ==  1
    let effs = internalSigilEffectRegistry.registered().toSeq()
    check effs.len() == 1
    # check effs[0].isDirty()
    # check internalSigilEffectRegistry.dirty().toSeq().len() == 1

    emit internalSigilEffectRegistry.triggerEffects()
    let effs2 = internalSigilEffectRegistry.registered().toSeq()
    echo "effs: ", effs2
    check effs2.len() == 1
    check internalSigilEffectRegistry.dirty().toSeq().len() == 0

    # a = signal(0)
    # effect(() => ... stuff that uses this.a() ...)
