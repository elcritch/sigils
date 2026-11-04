# Binary size implementation review

## Scope and reproduction

Sigils branch: `perf/share-signal-dispatch`, version 0.33.0. Companion Merenda
branch: `perf/sigils-compact-metadata`. Measurements use Nim 2.4.0, macOS arm64,
ARC, threads, release, `--opt:size`, and native debug information. No stripping,
LTO, changed checks, or runtime-name hashing is part of this change.

## 1. Baseline and attribution

The initially inspected, older Kosmo executable was 37,648,088 bytes. Its symbol
and symbol-name tables accounted for 17,098,984 bytes. Approximately 870,772 bytes
of text belonged to callSlotsLocal, including 81 main symbols and 738 cold
fragments (not 819 independent generic instantiations). Cached generated C had
about 61 KB of declaration strings and 16 KB of Variant nil-error messages.
These snapshots were from different builds; they are attribution clues, not an
A/B measurement or promised savings.

Size comparisons below use `size -m` for machine code separately from total file
size. Shipping stripped binaries remains a packaging decision: Merenda bundles
dSYMs and uses libbacktrace, so stripping requires its own symbolication checks.

## 2. Shared signal dispatcher

Subscription traversal, actor snapshots, lookahead, direct/packed selection,
endpoint liveness, and response checking now share non-generic implementation.
Only the payload packing/cloning adapter depends on the argument type.

The raw argument pointer is borrowed synchronously. Queued delivery receives
owned SigilParams. Last-recipient moves, non-final clone policy, ordinary direct
reference identity, and sink-slot cloning remain unchanged. No sequence snapshot
was added to ordinary fanout: the existing lookahead mutation behavior remains.

First attempt: moving the sole-recipient path into the shared dispatcher made
an early 10M-emission run take 465 ms. Moving it back reduced an early run to
298 ms. These were both draft implementations under build load. The
final implementation keeps that small path in the inline typed entry point.
The larger fanout/actor path remains shared. Early concurrent-build timing runs
are not suitable evidence of a throughput improvement.

## 3. Wrappers, inlining, and errors

Local selector invocation initialization now accepts pointers rather than
specializing on both argument and result types. Generated selector values use
an object constructor instead of a static-name generic initSelector call.
Public constructors and the public SigilLocalCall representation are unchanged.
Signal constructors and emit are not blanket-inlined: source-type erasure would
change a public representation, while the dominant duplicated work was inside
callSlotsLocal. The typed fast path gives the compiler a small inline boundary
without replicating the large dispatcher.

Slot macros preserve inline/noinline on the user implementation and forward
declaration. A macro-level regression assertion verifies inline preservation.
Other pragmas were not copied indiscriminately: generated adapter signatures
have different contracts. Address-taken adapters and the dispatch engine were
not blanket-inlined.

Unhandled-selector and destructive Variant nil errors have shared cold helpers.
Destructive Variant extraction retains detailed type text with variantDebugTypes.
The separate Variant dependency's get() still emits typed nil-error strings;
modifying that dependency is deferred rather than silently vendoring a patch.

## 4. Protocol metadata

Generated signatures contain declarations only, never slot bodies/comments.
The new booldefine `sigilsProtocolSignatures` defaults to true for compatibility;
`-d:sigilsProtocolSignatures=false` omits generated diagnostic signatures.
Manually supplied signature strings remain caller-controlled.

ProtocolRequirement.valueType stores a property setter's type spelling, generated
from the AST. It covers the same single `value` parameter and `setX`/`x=` shapes
previously recognized by Merenda. Getter existence, namespacing, and resource
registration remain Merenda's responsibility. This deliberately adds one small
metadata field instead of a new property registry or a type-ID protocol.

Merenda now consumes valueType directly, requires Sigils >= 0.33.0, and disables
verbose signatures. Disabling signatures without this migration would silently
lose resource property registrations. Tests cover both signature settings,
setter styles, unrelated methods, and exclusion of implementation bodies.

## 5. Runtime names

Signal/selector names, dynamic string lookup, and transport names are unchanged.
The low-risk specialization win is in generated selector construction. Numeric
or interned identifiers are deferred: they need collision handling, dynamic
lookup/transport compatibility, and profiling. Interning alone retains the name
strings and would not establish a binary-size win.

## 6. Validation, results, and obstacles

- Full `atlas-run tests --only-errors`: 55/56 passed. RChan's recvIso ownership
  test expects no additional move hook, but Nim 2.4.0 reports one extra move.
  Running that test against the unmodified Merenda Sigils 0.32.1 dependency
  reproduces the same failure. No RChan implementation was changed.
- After the fast-path adjustment: ten focused slot, generic, thread, closure,
  selector, and clone-routing selections passed.
- Metadata/selector tests pass with signatures disabled; ordinary defaults pass.
- ORC: slots, cloneRouting, and protocolMetadata passed (3/3).
- AddressSanitizer: tslots passed with useMalloc/noSignalHandler and sanitizer
  flags on both compilation and linking.
- The release tslots machine-code section fell from 299,704 to 218,648 bytes
  (27.0%); this is a test executable, not a Kosmo savings estimate.

Merenda integration obstacles:

1. An initial baseline build overlapped the resource-registry edit and failed
   against the old dependency. It was discarded, original files restored for
   the complete baseline build, and edits reapplied afterward.
2. Adding --path did not displace Merenda's installed Sigils module resolution;
   the resulting missing valueType error exposed this. Those builds are not
   counted as successful validation or measurements.
3. `atlas link ../sigils` failed on Merenda's existing variant #fix/ic-type-ids
   requirement, which the resolver could not resolve. Validation therefore uses
   a temporary dependency-path symlink, preserving the original checkout as
   deps/sigils-before-size-review. Restore it after validation. No generated
   dependency paths or third-party source patches are committed.

4. I incorrectly treated repeated incremental frontend passes as a stall and
   stopped the build for a `nim c` retry. The user clarified that these passes
   are normal and initial ic builds take roughly three minutes. This was an investigation mistake, not an established compiler
   failure. No cache deletion or backend change was committed.
5. The first scratch baseline filenames used hyphens, which Nim rejects as
   module identifiers. They were renamed. A benchmark --path override also
   selected the wrong implementation, so that baseline was discarded. Final
   benchmark baselines use scratch modules outside the repository and verified
   symbols to distinguish the old and new dispatcher.

Merenda hello A/B (`nim c --opt:size --out:/tmp/merenda-hello-{before,after}
examples/hello.nim`; original configuration for before, compact metadata for after):

| Metric | Before | After | Reduction |
| --- | ---: | ---: | ---: |
| File bytes | 13,102,616 | 12,315,696 | 786,920 (6.0%) |
| Machine code (`__text`) | 5,065,436 | 4,641,728 | 423,708 (8.4%) |
| Text constants | 1,087,928 | 1,017,120 | 70,808 (6.5%) |

The after executable contains dispatchLocalPayload; before does not. The demo
also ran for five seconds and initialized its native Metal window, then was
terminated deliberately. This is startup smoke coverage, not a visual UI audit.

The shared NimKit runner compiled successfully with `nim c -r
--out:/tmp/merenda-nimkit-size-review tests/tnimkit.nim 'NimKit resources::*'`.
All 15 selected resource tests passed with signatures disabled, including
automatic property discovery/binding. The other suites were compiled but not run.

Final single-recipient throughput smoke comparison (10M emissions, three
alternating runs, original dependency vs this checkout, verified symbols):

- Before: 213,109 / 210,094 / 208,879 microseconds; median 210,094.
- After: 172,207 / 171,251 / 171,060 microseconds; median 171,251.
- Median elapsed time decreased 18.5%. This is one hot-path microbenchmark on
  this machine, with another build running; it does not establish whole-app or
  multi-recipient throughput. Ignore the harness's methodRatio=inf when filtering
  out its method baseline. Correctness assertions passed in all six runs.

## 7. Follow-up: RChan specialization

RChanData[T] currently combines synchronization state with seq[Isolated[T]].
channelSend[T] additionally specializes for static blocking/overwrite flags;
channelReceive[T] specializes for static blocking. The queue bookkeeping does
not fundamentally require T. In the fresh Kosmo baseline, symbol extents for
allocChannel/freeChannel/channelSend/channelReceive total about 6,088 bytes
(including cold fragments; excluding other wrappers and lifetime hooks). This is
a real reuse opportunity but currently much smaller than signal dispatch in
Kosmo, so its priority should reflect payload diversity in other consumers too.

A separate experiment should use a non-generic ring/synchronization header,
shared send/receive bookkeeping, and small typed allocation/swap/destruction
adapters. Compare runtime policy flags with the existing static modes. Preserve
alignment, zero-initialized vacant slots, move-only ownership, and typed cleanup.
Payload hooks must never execute under the lock; overwritten payload destruction
must remain outside it. Final-owner teardown must detach storage before running
reentrant destructors. Do not substitute unchecked byte copying for these rules.

Measure distinct payload counts and text size, then run FIFO, overwrite, blocking,
concurrency, reentrant-hook, exception, and ARC/ORC tests. Resolve or explain the
baseline recvIso hook-count mismatch before using it as a regression gate. This
item is intentionally a follow-up, not an unmeasured channel rewrite in this PR.

## Final Kosmo rebuild

Both builds succeeded using `nim c --opt:size --debugger:native --lineTrace:off
--stackTrace:off -d:moe.embedded --out:/tmp/kosmo-size-{before,after}
src/merenda/kosmo/kosmo.nim`. Baseline used Sigils 0.32.1 and original resource
metadata/config; after used this branch and compact metadata. Symbols verify
that only the after executable contains dispatchLocalPayload. No stripping or
LTO was used. Outputs and dSYMs are in /tmp; the existing Kosmo executable and
installed app were not overwritten.

| Metric | Before | After | Reduction |
| --- | ---: | ---: | ---: |
| File bytes | 31,707,696 | 30,417,968 | 1,289,728 (4.1%) |
| Machine code (`__text`) | 11,817,508 | 11,011,100 | 806,408 (6.8%) |
| Text constants | 4,745,288 | 4,674,184 | 71,104 (1.5%) |

The temporary Sigils symlink and Atlas link metadata were removed after validation;
the original dependency checkout/config were restored. To rebuild the companion
Merenda branch, first install/link Sigils 0.33.0. It is intentionally an ordered
cross-repository change, not a published dependency release yet.
