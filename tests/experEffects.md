

# Proposal: Effect Handlers in Nim

Algebraic effects have been used successfully in a few different languages. 
Notably OCaml's multi-core primitives are built on it. 

Functional languages tend to wrap things up in talk of `monads` and such. 
However, algebraic effects can also be conceptualized as resumable exceptions 
(see [MSFT-Leijen2017](https://www.microsoft.com/en-us/research/wp-content/uploads/2017/06/algeff-in-c-tr-v2.pdf)).
It's in this sense that Nim could adopt algebraic effects into it's existing effects system.

Ideally the effect handlers would be transformed by the compiler after macro and tempplate expansions 
and would be used for lower level core constructs like `async`, `exceptions`, and `allocations`.

## Description

Algebraic effects are very simple at their core and reduce down to:

<img width="780" alt="image" src="https://gist.github.com/user-attachments/assets/aa3177d1-9077-4a73-9f3d-fd22196924f0" />

[XieLeijen2023](https://www.microsoft.com/en-us/research/uploads/prod/2021/03/multip-tr-v4.pdf)

## Use Cases

Algebraic effects are useful in a few different ways, but they can be used at compile time for useful transforms.

```nim
type AllocationEffect* = object

proc main*() =
  

```
