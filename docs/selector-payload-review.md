# Selector and payload reuse after PR #64

Base: `perf/share-signal-dispatch` at `0abe4cc` (PR #64). This follow-up measures
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
passed 4/4. API tests passed with debug type names enabled; the initial IC run
also passed. Further configuration and full-suite results follow below.

## Measurement setup

The Kosmo validation checkout is an isolated archive/worktree of Merenda
`a160f21c`, with a copy of its Atlas dependencies. Its Sigils dependency starts
at PR #64, then receives the measured follow-up changes. The original Merenda
checkout, installed app, dependency checkout, and build cache are left intact.

Command: `nim c --opt:speed --debugger:native --lineTrace:off --stackTrace:off
-d:moe.embedded --out:<output> src/merenda/kosmo/kosmo.nim`.
