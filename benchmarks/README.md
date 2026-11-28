# Benchmarks

## Dispatch specialization

`dispatchScaling.nim` generates and calls distinct selector methods, signal/slot
pairs, and typed RChans. Vary adapter count independently from payload type count
to distinguish code growth per adapter from growth per payload type. The payload
has an integer and a string; selectors/signals use a 32-byte string, and channels
transfer the integer with an empty string. A checksum verifies all operations.

From the Atlas-configured Sigils checkout:

```sh
nim c -r --mm:arc --threads:on -d:release --opt:speed --path:. \
  -d:scalingTypes=4 -d:scalingMethods=16 \
  -d:scalingSignals=16 -d:scalingChannels=4 \
  -d:scalingIterations=100000 \
  --out:/tmp/sigils-dispatch-scaling benchmarks/dispatchScaling.nim
```

Defaults are four payload types, 16 selector methods, no signals/channels, and
100,000 iterations. Counts can be zero except types and iterations. Each category
reports elapsed microseconds; initialization and connection setup are excluded.

For a size series, try 1, 16, and 64 methods with one payload type, then repeat
with the same number of types as methods. Repeat for signals and channels while
setting the other categories to zero. Keep compiler, dependency versions, flags,
and build paths identical between revisions. Measure executable machine code
(`__TEXT,__text` on macOS, `.text` on ELF/PE), separately from total file size,
which includes symbols and debug metadata.

For timing, alternate before/after binaries for several trials on an otherwise
idle machine and compare medians. This is a synchronous dispatch microbenchmark,
not a GUI performance estimate or a pass/fail timing test. RChan runs on one
thread and does not measure contention, and no allocation counter is provided.

## Persistent protocol and slot storage

`withProto()` and `withProtocol(Variant)` share trie roots for generated,
noncapturing methods. Each thread caches the initial map and the most recent
composition for each implementation. Per-agent method stacks handle
swizzling and stateful methods.

The hybrid-table comparisons below were run when Thetos was opt-in. Use
`git show 9cfc0c6:benchmarks/README.md` for the comparison commands on that
revision. The commands below use the current default protocol storage.

### Merenda views

Run from an Atlas-configured Merenda checkout that resolves `sigils` to
`../sigils`. The benchmark constructs and retains real `newView()` objects,
including their default responder, view, and accessibility protocol installations.
It warms the protocol caches with one view before measuring retained heap bytes
and dispatches the real `tag` and `hidden` selectors. The heap delta includes all
per-view allocations. `-u:useMalloc` selects Nim's allocator for heap accounting.

```sh
probe=$(mktemp -d tests/sigilsThetosBench.XXXXXX)
cp ../sigils/benchmarks/thetosMerenda.nim "$probe/thetosMerenda.nim"
nim c -d:release -u:useMalloc \
  --path:../sigils/deps/thetos/src \
  --out:/tmp/sigils-merenda-thetos "$probe/thetosMerenda.nim"
for sample in 1 2 3 4 5; do
  /tmp/sigils-merenda-thetos
done
rm "$probe/thetosMerenda.nim"
rmdir "$probe"
```

Historical five-trial medians on an Apple M3 Pro with Nim 2.2.12, Merenda `8a96a973`,
and Thetos `30f8c04`, using 20,000 views per trial.

| Protocol storage | Creation time (µs/view) | Retained heap (bytes/view) | Selector dispatch (ns/call) |
| --- | ---: | ---: | ---: |
| Hybrid table | 20.83 | 21,520 | 231.7 |
| Initial trie roots shared | 10.50 | 10,496 | 141.5 |
| Initial and composed roots shared | 3.80 | 5,696 | 90.6 |

The middle row is an intermediate prototype that rebuilt the same merged
trie for every new view. Remembering the merged root made repeated
construction 2.8× faster than that prototype and saved another 4,800 bytes
per view. This workload measures construction and selector dispatch in isolation.

### Merenda layout and collection rows

Merenda's existing headless benchmarks exercise more of the widget lifecycle.
`benchmark_layout_pipeline.nim` runs the DirectView task demo through cached
render builds, counter changes, title edits, reordering, and resizing.
`benchmark_collection_rows.nim` measures mounting and scrolling interactive
rows in materialized and virtualized collections. Both builds use Merenda's
usual allocator. The collection benchmark enables Merenda's profiling
instrumentation for both builds.

These results use the same machine and revisions as the view microbenchmark.
The layout numbers are medians of 25 timed operations per case across five
process launches. All 750 layout samples per build completed with matching
frame, priority, and diagnostic hashes.

| Operation on 100 tasks | Live baseline (ms/op) | Live Thetos (ms/op) | With preview baseline (ms/op) | With preview Thetos (ms/op) |
| --- | ---: | ---: | ---: | ---: |
| Update counter | 0.828 | 0.822 | 0.874 | 0.837 |
| Edit title | 2.103 | 2.023 | 42.717 | 25.392 |
| Reverse rows | 4.378 | 3.999 | 45.965 | 27.507 |
| Resize | 13.759 | 13.531 | 56.496 | 38.144 |

The collection results are medians of five runs with a 180-pixel viewport.
The 1,000-row materialized case hit the layout constraint limit in both
builds, so the table reports the completed cases.

| Collection | Items | Baseline mount (ms) | Thetos mount (ms) | Baseline scroll (ms) | Thetos scroll (ms) |
| --- | ---: | ---: | ---: | ---: | ---: |
| Materialized | 100 | 46.230 | 29.528 | 1.238 | 1.224 |
| Virtualized | 100 | 5.837 | 4.026 | 6.611 | 4.769 |
| Virtualized | 1,000 | 7.065 | 4.998 | 6.694 | 4.775 |

Run from the same Atlas-configured Merenda checkout.

```sh
bench_out=$(mktemp -d /tmp/sigils-merenda-workloads.XXXXXX)

nim c -d:release --path:../sigils/deps/thetos/src \
  --nimcache:"$bench_out/cache-layout" \
  --out:"$bench_out/layout" tests/benchmark_layout_pipeline.nim &&
nim c -d:release --path:../sigils/deps/thetos/src -d:merendaProfile \
  --nimcache:"$bench_out/cache-rows" \
  --out:"$bench_out/rows" tests/benchmark_collection_rows.nim &&
for sample in 1 2 3 4 5; do
  "$bench_out/layout" "$bench_out/layout-$sample.csv" &&
  "$bench_out/rows" > "$bench_out/rows-$sample.log" || break
done
```

### Ordinary slots

`thetosSlots.nim` compares the existing sorted subscription sequence with
signal-keyed `TrieMap` variants whose buckets use a boxed sequence or
`TrieVec`. Each trial builds at most 20,000 owners and exercises 1, 4, 16,
and 64 signal names with one to four receivers per signal. The larger
buckets use 64 receivers per signal and one or 16 signals. Those cases
use 62,500 lookups to cap the number of slot calls. Lookup includes walking
the matched buckets and calling a minimal slot. One quarter of lookups miss.
The benchmark uses prepared subscriptions and measures registration and lookup primitives.
The full connect and emit paths also do listener bookkeeping and payload handling.

Run from the Atlas-configured Sigils checkout with Thetos in `deps/thetos`.

```sh
nim c -d:release --mm:arc --threads:on --path:. \
  --out:/tmp/sigils-slots-stack-names benchmarks/thetosSlots.nim
nim c -d:release --mm:arc --threads:on --path:. -d:features.sigils.sigNameAsString \
  --out:/tmp/sigils-slots-string-names benchmarks/thetosSlots.nim
for sample in 1 2 3 4 5; do
  /tmp/sigils-slots-stack-names
  /tmp/sigils-slots-string-names
done
```

Five-trial medians from the boxed-trie comparison. Each cell gives the
sorted sequence followed by the boxed trie.

| Signals per owner | Receivers per signal | Stack-name lookup (ns) | String-name lookup (ns) | Stack-name retained heap (bytes/owner) | String-name retained heap (bytes/owner) |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 1 | 14 → 45 | 14 → 45 | 192 → 288 | 176 → 272 |
| 1 | 2 | 28 → 54 | 20 → 53 | 304 → 336 | 272 → 320 |
| 1 | 3 | 40 → 62 | 25 → 68 | 528 → 432 | 432 → 416 |
| 1 | 4 | 54 → 68 | 29 → 73 | 528 → 528 | 464 → 512 |
| 4 | 1 | 56 → 46 | 25 → 47 | 528 → 800 | 464 → 736 |
| 4 | 2 | 103 → 63 | 39 → 57 | 976 → 992 | 848 → 928 |
| 4 | 3 | 155 → 66 | 57 → 75 | 1,872 → 1,376 | 1,488 → 1,312 |
| 4 | 4 | 723 → 114 | 101 → 110 | 1,872 → 1,760 | 1,616 → 1,696 |
| 16 | 1 | 727 → 186 | 92 → 147 | 1,872 → 2,880 | 1,616 → 2,624 |
| 16 | 2 | 880 → 129 | 267 → 111 | 3,664 → 3,648 | 3,152 → 3,392 |
| 16 | 3 | 1,053 → 97 | 338 → 91 | 8,256 → 5,184 | 9,792 → 4,928 |
| 16 | 4 | 1,164 → 144 | 386 → 134 | 8,256 → 6,720 | 10,304 → 6,464 |
| 64 | 1 | 1,166 → 219 | 381 → 186 | 8,256 → 11,488 | 10,304 → 10,464 |
| 64 | 2 | 1,295 → 175 | 348 → 137 | 16,448 → 14,560 | 16,448 → 13,536 |
| 64 | 3 | 1,330 → 147 | 372 → 142 | 32,832 → 20,704 | 26,688 → 19,680 |
| 64 | 4 | 1,326 → 101 | 382 → 103 | 32,832 → 26,848 | 28,736 → 25,824 |

With string names, setup went from 42 to 87 ns/connection for one signal
and one receiver, and from 198 to 127 ns/connection for 64 signals and four
receivers. The small cases favor the sorted sequence. Large groups benefit
from storing the signal name once per bucket. The sorted sequence's binary
search also converts stack names to strings, which helps explain the larger
lookup gaps with stack names. The boxed trie lives in this benchmark.

#### TrieVec buckets

The vector variant runs the same signal-keyed lookup with `TrieVec`
buckets. The two trie variants append to each bucket in connection order.
The trie lookup and wildcard handling stay the same across both bucket types.

Five-trial medians with string names. Each cell lists the sorted sequence,
boxed trie, and vector trie in that order.

| Signals per owner | Receivers per signal | Setup (ns/connection) | Lookup (ns) | Retained heap (bytes/owner) |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 1 | 43 / 94 / 254 | 16 / 47 / 76 | 176 / 272 / 1,792 |
| 1 | 2 | 45 / 104 / 130 | 22 / 55 / 80 | 272 / 320 / 1,792 |
| 1 | 3 | 50 / 113 / 138 | 28 / 70 / 83 | 432 / 416 / 1,792 |
| 16 | 4 | 137 / 136 / 180 | 491 / 151 / 184 | 10,304 / 6,464 / 26,592 |
| 64 | 4 | 202 / 143 / 193 | 441 / 119 / 153 | 28,736 / 25,824 / 106,288 |
| 1 | 64 | 162 / 350 / 251 | 806 / 579 / 270 | 10,304 / 8,400 / 3,648 |
| 16 | 64 | 1,378 / 352 / 252 | 1,007 / 563 / 259 | 102,464 / 132,672 / 56,288 |

`TrieVec` allocates room for 32 entries with the first subscription in a
bucket. This drove up retained heap in the one-to-four receiver cases.
With 64 receivers per signal, the vector trie had the fastest lookup and
lowest retained heap in both measured cases with stack and string names.
The allocation tradeoff follows receivers per signal, so 64 signals
with four receivers each used more vector heap than 16 signals with 64
receivers each.

#### Sorted sequence through the signal API

`seqSlots.nim` uses plain `Agent` objects with their sorted subscription
sequence with stack and string names. It measures the real `connect`, `emit`,
and `disconnect` paths using declared signals and a local integer slot.
Every emit hits a connected signal. The benchmark verifies the delivered
values and checks that all listener links are removed. The heap delta
starts after allocating the agents and includes subscription entries,
listener sets, and endpoints created during connection.

```sh
nim c -d:release --mm:arc --threads:on --path:. \
  --out:/tmp/sigils-seq-slots-stack benchmarks/seqSlots.nim
nim c -d:release --mm:arc --threads:on --path:. -d:features.sigils.sigNameAsString \
  --out:/tmp/sigils-seq-slots-string benchmarks/seqSlots.nim
for sample in 1 2 3 4 5; do
  if [ "$((sample % 2))" -eq 1 ]; then
    /tmp/sigils-seq-slots-stack
    /tmp/sigils-seq-slots-string
  else
    /tmp/sigils-seq-slots-string
    /tmp/sigils-seq-slots-stack
  fi
done
```

Five-trial medians on the same machine. Each cell lists StackString followed
by plain string.

| Signals per source | Receivers per signal | Connect (ns/connection) | Emit (ns/emission) | Disconnect (ns/connection) | Retained heap (bytes/source) |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 1 | 118 / 102 | 26.0 / 19.0 | 83.0 / 57.2 | 161 / 113 |
| 1 | 2 | 171 / 115 | 85.9 / 71.1 | 95.9 / 66.3 | 306 / 210 |
| 1 | 3 | 210 / 124 | 125 / 99 | 110 / 74 | 563 / 371 |
| 16 | 3 | 406 / 134 | 940 / 226 | 797 / 273 | 9,493 / 9,493 |
| 16 | 64 | 1,071 / 287 | 3,821 / 2,137 | 5,708 / 3,752 | 154,112 / 104,960 |
| 64 | 4 | 561 / 143 | 1,356 / 358 | 2,019 / 992 | 45,200 / 32,912 |
