# Selector and payload reuse after PR #64

Base: merged PR #64 at `3578d80` (the same tree as its former head `0abe4cc`). This follow-up measures
`--opt:speed`, per the requested Kosmo build policy. Earlier `--opt:size` results
are not directly comparable.

## 1. Shared cold error paths

Generated selector and slot adapters used to construct identical exceptions in
every wrapper. Private `noinline, noreturn` helpers now construct the nil receiver,
invalid receiver, and non-copyable slot payload exceptions. The exception types
and messages are unchanged. Helpers remain private within their owning modules;
there is no new public error API and receiver downcasts retain their checks.

Validation: `atlas-run tests selectors.nim slots.nim` passed 2/2. Size and runtime
measurements are recorded below after the matching before/after builds finish.

The isolated speed build confirms this change alone reduces Kosmo's machine
code by 132,848 bytes (12,412,912 to 12,280,064), and its unstripped file by
182,136 bytes (32,145,336 to 31,963,200). These are matching builds from the same
checkout/cache with only the cold helper change applied.

## 2. Borrowed local selector arguments

Generated selector, protocol implementation, typed closure, and typed callback
adapters now borrow local arguments instead of copying them out of Invocation.
The private lent accessor returns the caller-owned argument storage, which stays
alive throughout synchronous dispatch. Packed calls decode into adapter-owned
fallback storage. Public argsAs still returns an independent value.

Focused ownership tests show one payload copy per adapter before this change
and zero afterward for single arguments, tuples, and typed callbacks. Coverage
also checks protocol implementations, retaining a value from a typed closure,
around methods invoking the same payload twice, reusable packed invocations,
and public argsAs copy independence. Selector and payload suites with closure
support passed 2/2. The accessor's fallback storage must be its first parameter
to satisfy Nim's lent-return borrowing rule; the initial opposite ordering was
rejected by the compiler and corrected.

The unmodified PR #64 baseline also passed the full Merenda suite: 2,068 tests,
175 suites, all four runners, no failures/skips, 19m13s, Nim 2.4.0 on macOS arm64.
Logs are under `/tmp/merenda-pr64-full-suite-20261104/`. That run validates the
base, not these new changes.

Borrowing alone reduces another 8,172 machine-code bytes and 35,704 file bytes
in Kosmo: 12,271,892 code bytes and a 31,927,496-byte unstripped executable.
The scaling benchmark (16 methods, four payload types containing strings,
100,000 iterations per method) ran seven alternating trials. Median selector
time was 164,618 us with cold errors alone versus 137,713 us with borrowing,
about 16.3% lower. Both binaries were compiled from the same benchmark source
in the isolated Merenda checkout; this microbenchmark is not a GUI workload.

## 3. Sigils-owned Variant

Removed the `variant` package requirement and the textual `include variant`.
Sigils now owns the implementation in `sigils/svariant.nim`, adapted from the
MIT-licensed upstream code and Merenda's `fix/ic-type-ids` work (f1dcfec). The
original license is retained in the source. The established constructors,
get/ofType/isEmpty, variantMatch, owned extraction, and clone adapters remain.

The compile-time counter was deliberately not brought back: cached sibling IC
modules need matching type identities. The owned implementation uses the same
canonical type signatures and collision-checked hash cache used by Merenda,
with a Sigils-specific cache namespace. IDs are build-local, not persistent or
wire values. Nominal types from different modules must remain distinct even
when they share names and layouts. Procedure calling conventions/effects and
closure conversion behavior are preserved.

Both ordinary get and destructive take now share cold failure helpers. Without
`variantDebugTypes`, failures omit per-type diagnostic strings; the debug switch
retains expected/actual type text. Exception types remain unchanged. Typed
payload refs still use Nim's ordinary ARC/ORC ownership rather than raw buffers.

New coverage caught and fixed two inherited issues: removing closure pragmas
while iterating forward could index beyond the shrinking pragma list, and
variantMatch could evaluate a side-effecting subject twice. The former now
iterates backward; the latter binds its subject once before matching.

Atlas `install -k` succeeds and regenerates nim.cfg without a Variant path.
Focused ownership, thread delivery, caller-name collision, and payload tests
passed 4/4. API tests passed with debug type names enabled, Nim 2.4 initial and
warmed IC builds, and Nim 2.2.10 C compilation. ORC passed four focused suites;
AddressSanitizer with `useMalloc` passed the API, ownership, and payload suites.
The owned Variant stage alone removes another 29,112 machine-code bytes and
65,568 file bytes from Kosmo.

## 4. Local versus packed selector paths: rejected experiment

Tried private `noinline` packing/unpacking helpers shared by payload type,
alongside an explicitly `inline` setResult so local dispatch could keep only
the pointer write. The full Sigils suite passed 58/58 with that experiment, but
the matching Kosmo build grew by 75,804 code bytes and 176,480 file bytes over
the owned Variant stage. Removing forced setResult inlining still grew code by
11,364 bytes and the file by 40,656 bytes. Both variants were discarded.

Thus the final change borrows local arguments and shares cold errors, but leaves
packing and setResult's existing compiler decisions intact. A second local-only
adapter/dispatch table was not added: it would introduce more wrappers and
state for an unproven benefit. The size data does not justify that complexity.
These results also show why a small source-level helper is not automatically a
smaller executable under `--opt:speed`.

## 5. Table and RChan specialization audit

Selector methods use one `SelectorMethodStore[DynamicMethod]` specialization
regardless of selector argument/result types. Agent subscriptions are already a
shared `seq[SubscriptionEntry]`, not a table specialized for every payload.
The remaining generic tables serve different values: actor references, timer
handles/deadlines, pool state, registry locations, proxy entries, and RPC routes.
The previously reported stdlib table code is application-wide, not all Sigils.

No additional table erasure was made. It would require new ownership/destructor
adapters or boxed values while offering no per-selector specialization reduction
in the primary store. RChan retains PR #64's shared synchronization/ring core and
typed transfer/destruction adapters. Its descriptor allocation is a possible
separate allocation optimization, not required by the Variant replacement;
this PR does not change its lifetime or reentrancy rules.

## 6. Repeatable specialization benchmark

Added `benchmarks/dispatchScaling.nim` and invocation guidance. Independent
adapter and payload-type counts cover selectors, signal/slot pairs, and RChans.
Every generated adapter is invoked and a checksum checks its result. Timing
excludes setup; it measures synchronous operations, not GUI work or channel
contention. No allocation counter or brittle timing threshold was added.

Final selector-only size series (1,000 iterations, ARC, release, speed, same
Atlas configuration):

| Methods | Payload types | Machine-code bytes |
| ---: | ---: | ---: |
| 1 | 1 | 249,512 |
| 16 | 1 | 257,984 |
| 64 | 1 | 283,528 |
| 16 | 16 | 276,600 |
| 64 | 64 | 361,472 |

These include runtime/library startup code. The series makes both adapter and
payload specialization costs visible; it is not a count of Sigils code alone.

## Size results

All sizes are bytes from matching macOS arm64 `--opt:speed` builds. File sizes
are unstripped; code is `__TEXT,__text`, excluding assets and symbols.

| Stage | Machine code | Executable file | Code change from preceding kept stage |
| --- | ---: | ---: | ---: |
| PR #64 | 12,412,912 | 32,145,336 | — |
| Shared cold errors | 12,280,064 | 31,963,200 | -132,848 |
| Borrowed local arguments | 12,271,892 | 31,927,496 | -8,172 |
| Owned Variant (final) | 12,242,780 | 31,861,928 | -29,112 |

Total: **170,132 fewer machine-code bytes (1.37%)** and **283,408 fewer file
bytes (0.88%)**. Rejected packing experiments are excluded from these savings.

## Validation limitations found

Focused selector payload tests pass with `sigilsJsonSerde` and `sigilsCborSerde`.
The entire selector suite cannot be used as a JSON-backend test: `core.nim` has
a pre-existing response guard that recognizes `useJsonSerde` but not its newer
`sigilsJsonSerde` alias, and correcting that guard then reaches unsupported JSON
serialization of `DynamicMethod` callbacks in the suite's object fixtures.
The guard issue is also present in PR #64. The trial correction was reverted;
backend-wide JSON compatibility is outside this optimization, and the passing
default suite must not be presented as validating every serialization mode.

## Measurement setup

The Kosmo validation checkout is an isolated archive/worktree of Merenda
`a160f21c`, with a copy of its Atlas dependencies. Its Sigils dependency starts
at PR #64, then receives the measured follow-up changes. The original Merenda
checkout, installed app, dependency checkout, and build cache are left intact.

Command: `nim c --opt:speed --debugger:native --lineTrace:off --stackTrace:off
-d:moe.embedded --out:<output> src/merenda/kosmo/kosmo.nim`.
