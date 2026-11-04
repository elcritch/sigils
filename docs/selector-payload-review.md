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

## Measurement setup

The Kosmo validation checkout is an isolated archive/worktree of Merenda
`a160f21c`, with a copy of its Atlas dependencies. Its Sigils dependency starts
at PR #64, then receives the measured follow-up changes. The original Merenda
checkout, installed app, dependency checkout, and build cache are left intact.

Command: `nim c --opt:speed --debugger:native --lineTrace:off --stackTrace:off
-d:moe.embedded --out:<output> src/merenda/kosmo/kosmo.nim`.
