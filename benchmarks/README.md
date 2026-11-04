# Dispatch specialization benchmark

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

## Signal-name storage experiment

See [the review](../docs/shared-name-review.md) for the recommendation, caveats,
and Kosmo results. The experimental shared backend is not a supported third
naming configuration; the existing StackString and string choices remain the
production choices. `classNames.nim` and `descriptorNames.nim` are benchmark
controls, not library APIs.

```sh
# Change nameBackend to stack, direct, string, shared, class, or descriptor.
nim c -r --mm:arc --threads:on -d:release --opt:speed -d:useMalloc --path:. \
  -d:nameBackend=shared --out:/tmp/name-storage benchmarks/nameStorage.nim

# Allocation counts are a separate run; do not use instrumented timings.
nim c -r --mm:arc --threads:on -d:release --opt:speed -d:useMalloc --path:. \
  -d:nimAllocStats -d:nameBackend=shared \
  --out:/tmp/name-allocations benchmarks/nameStorage.nim

# The ref-subclass control requires atomic ARC for thread-safe refcounts.
nim c -r --mm:atomicArc --threads:on -d:release --opt:speed -d:useMalloc --path:. \
  -d:nameBackend=class --out:/tmp/name-class-atomic benchmarks/nameStorage.nim

# Inspect complete Sigils record layouts with the selected naming option.
nim c -r --mm:arc --threads:on -d:release --path:. -d:sigilsSharedNames \
  --out:/tmp/name-layout benchmarks/nameLayout.nim
```

The `stack`/`direct` microbenchmark controls preserve the old/new comparator
independently of the installed Sigils default. To reproduce the old/new full
dispatch comparison, use commit `06894df` with and without
`-d:sigilsDirectNameCompare`; the final branch always uses direct comparison.
Use `-d:sigilsSigilNameString` or experimental `-d:sigilsSharedNames` for the
other dispatch runs. Measurements used `scalingMethods=16`, `scalingSignals=16`,
`scalingTypes=4`, and `scalingIterations=100000`.

For Merenda `a160f21c`, copy its Atlas dependencies into an isolated checkout,
replace only its Sigils dependency with this branch, then apply
`merenda-shared-names.patch`. Build Kosmo with the review's speed flags. The
shared build additionally needs `-u:features.sigils.sigNameAsString
-u:feature.sigils.sigNameAsString -d:sigilsSharedNames` because Merenda's Atlas
configuration selects strings. Keep the same compatibility edits in the string
baseline. Do not combine the string and shared defines.

Raw seven-trial timings and size/layout measurements are retained in
`results/name-storage-macos-arm64.json`. Tests and measurements are not a claim
that the experimental backend supports all platforms or serialization modes.
