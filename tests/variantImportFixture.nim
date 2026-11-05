## Simulate a caller importing an unrelated Variant API, without depending on
## another package. Generated Sigils adapters must bind Sigils' own symbols.
type Variant* = object
  value*: int

proc newVariant*(value: int): Variant =
  Variant(value: value)
