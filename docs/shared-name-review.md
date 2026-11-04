# Signal-name storage experiment

Base: PR #65, `687c5b6`; branch `perf/shared-sigil-names`.

## Question and candidates

Can immutable reference-counted names reduce the cost of copying signal and
protocol names, while borrowing compile-time literals directly from executable
data? Compare the existing `StackString[48]` and Nim `string` options against:

- A 16-byte value with a pointer and signed length. Nonnegative length denotes
  borrowed literal storage; negative length denotes one dynamically allocated
  block containing an atomic owner count followed by immutable bytes. Static
  copies do not retain anything; dynamic copies increment the count.
- A subclass control: `LiteralName` and `DynamicName` inherit from a reference
  base, with virtual byte access. A literal descriptor is shared per literal;
  dynamic descriptors own Nim strings. Measure ordinary ARC and atomic ARC.
  Ordinary ARC subclass sharing is only a single-threaded benchmark control,
  not a proposed cross-thread backend.
- A control that keeps StackString storage and compares bytes directly. The
  original `compareSigilName` converts both operands to temporary Nim strings;
  improvements from eliminating those allocations are not evidence for a new
  name representation.

The compact prototype is selected with `-d:sigilsSharedNames`. This is an
experimental switch while the tradeoffs are being measured, not a default
change. `-d:sigilsDirectNameCompare` selects the StackString comparison control.

## Ownership and compatibility choices

Dynamic input is copied into a single shared allocation; a runtime `cstring`
must never be mistaken for immortal executable data. Only the `static string`
constructor borrows. Fields are private, names are immutable, equality and hash
use bytes, and static/dynamic representations compare identically. Copying
retains before releasing the old destination, so self-assignment is safe.
Nim synthesizes the sink and moved-from reset. There is no custom sink or raw
copy of child-managed values. Clone overloads retain immutable storage, making
delivery copies safe with ARC and ORC without requiring atomic ARC globally.

One real limitation surfaced: a `const` containing a `cstring` with embedded NUL
is exported by Nim's VM as a truncated C literal while retaining the original
length. The first prototype therefore read beyond that literal. The regression
test caught this; the constructor now rejects NUL at compile time for literals
and with ValueError for dynamic input. This is a semantic restriction relative
to Nim strings. UTF-8 and empty names remain supported. VM ownership hooks must
also omit runtime atomic operations and allocation counters.

The subclass design has an eight-byte handle, but adds a heap descriptor even
for static literals and requires runtime type metadata and virtual access.
Using ordinary ARC refs would not provide safe shared ownership across threads;
atomic ARC changes the memory manager for the whole application. Integration
would also need explicit handling for Sigils' clone and isolation rules.

## Integration findings

Merenda explicitly selects `sigNameAsString` through Atlas, and NimKit rejects
other backends at compile time. Thus the real Kosmo baseline is Nim strings,
not StackString. The isolated validation checkout relaxes that guard for the
experiment and explicitly converts the control action name to a resource string.
These changes are recorded separately; the user's Merenda checkout is untouched.

The shared backend passed 58/59 initial Sigils suites. The remaining IPC test
assumed every backend has the StackString capacity limit. Its expectation now
distinguishes bounded StackString names (invalid request) from unbounded string
or shared names (unknown method); the focused IPC suite then passed.

## Measurement method

`benchmarks/nameStorage.nim` compares static/dynamic construction, copying,
ordering, and hash lookup with 512 names. It checks results, uses the same text
for each backend, and keeps setup outside timed sections. Run with
`-d:nimAllocStats` separately for allocation counts; timings with those counters
enabled are not used for recommendations. `benchmarks/classNames.nim` contains
the subclass control. `benchmarks/dispatchScaling.nim` measures actual selector
and signal dispatch under each integrated backend.

Kosmo uses Nim 2.4.0, macOS arm64, ARC, and `--opt:speed`, with copied Atlas
dependencies at Merenda `a160f21c`. Code measurements use `__TEXT,__text`,
excluding embedded assets and symbols. File sizes are unstripped.

Final measurements, validation, and recommendation follow after the experiments.
