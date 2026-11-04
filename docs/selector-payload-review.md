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

## Measurement setup

The Kosmo validation checkout is an isolated archive/worktree of Merenda
`a160f21c`, with a copy of its Atlas dependencies. Its Sigils dependency starts
at PR #64, then receives the measured follow-up changes. The original Merenda
checkout, installed app, dependency checkout, and build cache are left intact.

Command: `nim c --opt:speed --debugger:native --lineTrace:off --stackTrace:off
-d:moe.embedded --out:<output> src/merenda/kosmo/kosmo.nim`.
