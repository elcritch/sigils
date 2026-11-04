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
- A second subclass control uses static global descriptors, raw pointers to
  base/derived objects, and atomic ownership only for dynamic descriptors.
  This avoids allocating literal descriptors but adds indirection, runtime
  subtype checks, and larger per-name storage outside the eight-byte handle.
- A control that keeps StackString storage and compares bytes directly. The
  original `compareSigilName` converts both operands to temporary Nim strings;
  improvements from eliminating those allocations are not evidence for a new
  name representation.

The compact prototype is selected with `-d:sigilsSharedNames`. This is an
experimental switch while the tradeoffs are being measured, not a default
change. The direct StackString comparison was initially selected by
`-d:sigilsDirectNameCompare` in commit `06894df`; after measurement it became
the default comparison implementation.

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
The raw descriptor variant avoids those ARC ownership problems, but cannot
construct a Nim `const` name from the address of its global descriptor. A
focused compile probe fails; Sigils currently generates `const` signal names
and exports `const AnySigilName`. Adopting it would require changing those
declarations or additional compiler-specific static-data generation. Its
static descriptor occupies 24 bytes and its dynamic descriptor 32 bytes on
this target, before the text, versus an eight-byte dynamic header for the
compact representation.

## Integration findings

Merenda explicitly selects `sigNameAsString` through Atlas, and NimKit rejects
other backends at compile time. Thus the real Kosmo baseline is Nim strings,
not StackString. The isolated validation checkout relaxes that guard for the
experiment and explicitly converts the control action name to a resource string.
These changes are recorded separately; the user's Merenda checkout is untouched.
The reproducible patch is `benchmarks/merenda-shared-names.patch`. String equality
and prefix matching were added to the compact type for the existing call sites.
Its runtime constructor is pure from the caller's perspective; initializing a
fresh, unpublished atomic header needs an explicit local no-side-effect cast
to preserve Merenda's `func` constructors.

An attempted StackString Kosmo build, with the backend guard bypassed only for
the experiment, fails because
`ControlActivationFeedbackProtocol.setActivationFeedback` is 55 bytes and the
supported StackString capacity is 48. No full-app StackString size is claimed,
and the capacity was not silently increased for the comparison.

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

Both Kosmo builds use:

```sh
nim c --opt:speed --debugger:native --lineTrace:off --stackTrace:off \
  -d:moe.embedded --out:/tmp/kosmo-names-string src/merenda/kosmo/kosmo.nim
```

For the shared build, add `-u:features.sigils.sigNameAsString
-u:feature.sigils.sigNameAsString -d:sigilsSharedNames` and use a distinct output
path. See [benchmark instructions](../benchmarks/README.md) and the
[raw measurements](../benchmarks/results/name-storage-macos-arm64.json).

## Results

Seven runs, rotating backend order, medians in microseconds. Timings exclude
allocation instrumentation. Construction, comparison and lookup each perform
200,000 operations; copying performs 1,000 rounds of 512 names. These are short
13-byte names and a warm pool, not a general string benchmark.

| Backend | Handle bytes | Static construction | Dynamic construction | Static copy | Dynamic copy | Compare | Lookup |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| StackString, original comparator | 64 | 1,927 | 2,020 | 745 | 699 | 14,099 | 4,285 |
| StackString, direct comparator | 64 | 1,962 | 2,021 | 693 | 693 | 729 | 4,348 |
| Nim string | 16 | 197 | 3,347 | 694 | 2,557 | 791 | 2,276 |
| Compact shared name | 16 | 148 | 4,595 | 429 | 822 | 1,058 | 3,489 |
| Ref subclasses, ARC (single-thread control) | 8 | 470 | 6,481 | 567 | 555 | 1,696 | 4,701 |
| Ref subclasses, atomic ARC | 8 | 699 | 6,546 | 965 | 957 | 1,731 | 4,667 |
| Static/dynamic subclass descriptors | 8 | 296 | 3,700 | 665 | 855 | 807 | 2,935 |

The compact representation makes these dynamic copies about 3.1 times as fast
as Nim strings, but dynamic construction is 37% slower and hash lookup is 53%
slower. The string copy benchmark reuses destination capacity: it allocates
512 buffers on the first copying round, not one buffer on every later copy.
This matters when interpreting the allocation savings.

Separate allocation-counter runs confirm:

- Literal construction/copy has zero per-operation allocations for all backends
  after setup. Ref subclasses additionally allocate **512 descriptors at startup**;
  the raw static-descriptor control avoids those allocations.
- Dynamic construction allocates once per operation for Nim strings, compact
  shared names and raw descriptors; ref subclasses allocate twice.
- Original StackString comparison allocates **400,000 temporary strings for
  200,000 comparisons**. Direct byte comparison allocates zero.
- Shared and descriptor copies allocate zero. Descriptor teardown counters
  balance at 202,075 allocations and releases in the complete instrumented run.

The actual dispatch benchmark uses 16 selector methods, 16 connected signals,
four payload types, and 100,000 iterations per method/signal:

| Backend | Selector time (us) | Signal time (us) |
| --- | ---: | ---: |
| Original StackString comparison | 138,163 | 910,182 |
| Direct StackString comparison | 137,619 | 195,480 |
| Nim string | 137,225 | 183,917 |
| Compact shared name | 139,753 | 214,142 |

Direct comparison improves this signal benchmark **4.66 times**. It crosses the
16-subscription binary-search threshold, where name comparisons are frequent;
do not generalize that factor to every signal workload. Compact shared names
make the signal workload **16.4% slower than strings**. Selector differences are
small; the data does not show a meaningful selector speedup.

### Matching Kosmo builds

Both builds use the same two compatibility edits in the isolated Merenda tree.
An additional final string rebuild confirmed identical machine-code size to the
original unmodified Merenda baseline.

| Bytes | Nim string | Compact shared | Change |
| --- | ---: | ---: | ---: |
| Machine code | 12,242,780 | 12,289,332 | +46,552 |
| Unstripped executable | 31,853,672 | 31,700,624 | -153,048 |
| Executable after `strip -S -x` | 17,897,376 | 17,913,288 | +15,912 |

The apparently smaller unstripped file is misleading for this optimization:
symbol entries shrink by 87,488 bytes and the symbol string table by 80,160
bytes. Read-only constant data shrinks by 43,008 bytes, but C-string data grows
by 26,937 bytes and machine code grows by 46,552 bytes. The name handle stays
16 bytes, just like the string backend already used in Kosmo. Stripping was
performed only on temporary measurement copies; packaging was not changed.

The complete record layouts confirm that sharing does not reduce the in-memory
handle or containing records relative to the string backend:

| Type size in bytes | StackString | Nim string | Compact shared |
| --- | ---: | ---: | ---: |
| SigilName | 64 | 16 | 16 |
| SigilRequest | 104 | 56 | 56 |
| SubscriptionEntry | 112 | 64 | 64 |
| Invocation | 144 | 96 | 96 |
| Selector[int, int] | 64 | 16 | 16 |
| ProtocolRequirement | 104 | 56 | 56 |

These sizes exclude pointed-to storage. They do not establish whole-application
RSS savings; no Kosmo peak-RSS or interactive latency claim is made.

## Validation

- `atlas-run tests`: **60/60 test programs passed** with the default backend.
- `atlas-run tests -- -d:sigilsSharedNames`: **60/60 passed** after correcting the
  IPC capacity expectation and adding the comparison regression tests.
- Focused shared-name ownership tests passed with ORC, AddressSanitizer,
  ThreadSanitizer, and Nim 2.2.10. Initial and warm incremental builds of the
  protocol-signal tests passed with the shared backend.
- Comparison tests agree with string byte ordering, including compile-time
  comparisons. Allocation-counter checks confirm zero runtime comparison
  allocations for the direct StackString and shared backends.
- The descriptor benchmark passed AddressSanitizer; concurrent descriptor
  ownership checks passed ThreadSanitizer.
- In the isolated Merenda checkout, all **15 resource tests passed**, the
  button-counter demo built and initialized its Metal renderer, and remained
  running during an eight-second startup smoke test before being terminated.
  Both matching Kosmo builds completed. This is not an interactive GUI test.
- The full Merenda suite was **not rerun for this experiment**. The earlier
  2,068-test result in the selector review applies to PR #65, not these changes.

Measurements and sanitizer checks here are from macOS arm64. The prototype has
not received a full cross-platform or serialization-backend validation matrix.

## Recommendation

**Keep Nim strings for Kosmo and do not promote a third supported naming backend
on these results.** The compact prototype helps repeated copies of dynamic
names, but Kosmo already gets zero-allocation literals and a 16-byte handle from
Nim strings. It does not reduce deployed binary size here and loses in the
measured signal and lookup workloads. It also adds custom memory management,
atomic lifetime operations, the NUL restriction, backend-specific compatibility
work, and another configuration to maintain and test.

Keep the prototype opt-in on this experimental branch for workloads with many
long, repeatedly copied dynamic names. A demonstrated allocation/RSS bottleneck
there could justify revisiting it. Subclasses do not presently improve that
recommendation: the simple ref version adds allocations/virtual dispatch, while
the raw descriptor version trades a smaller handle for static descriptors,
indirection, runtime type checks, and const-initialization incompatibility.

**Keep the direct StackString comparator.** It preserves the existing storage,
capacity and ordering rules, including empty names, prefixes, arbitrary byte
values and embedded NULs, while removing avoidable allocations. Its compile-time
path retains the string-based comparison; a regression test caught and fixed
the need to assign the result explicitly in the `nimvm` branch.
