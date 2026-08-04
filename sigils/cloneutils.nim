import std/typetraits

proc clone*[T](value: T): T {.gcsafe.} =
  ## Clone a value recursively, preserving value semantics for managed fields.
  ##
  ## Strings and sequences use Nim's normal value-copy semantics.
  ## References are cloned recursively instead of sharing their target. Objects
  ## are copied before visiting their fields so case-object discriminants select
  ## the same active branch in both values.
  mixin clone

  when T is distinct:
    type Base = distinctBase(T, false)
    result = T(clone(Base(value)))
  elif T is ref:
    if not value.isNil:
      new result
      result[] = clone(value[])
  elif T is seq:
    result = value
    for index in 0 ..< value.len:
      result[index] = clone(value[index])
  elif T is array:
    result = value
    for index in low(value) .. high(value):
      result[index] = clone(value[index])
  elif T is tuple or T is object:
    result = value
    for resultField in fields(result):
      resultField = clone(resultField)
  else:
    result = value
