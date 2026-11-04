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
