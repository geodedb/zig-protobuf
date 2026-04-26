# Decision — P-04 inline packed-list writers

**Verdict:** PASS — accept the optimization.
**Date:** 2026-04-26
**`ref_a`:** `646ba3f` (main, post-P-05 merge)
**`ref_b`:** `1f47963` (this commit on `perf/p-04-inline-packed-write`)
**Summary line:** `NATIVE_BENCH result=PASS scenarios=18 regressions=0 improvements=1 ref_a=646ba3f3 ref_b=1f479632`

## Optimization under test

`writePackedFixedList`, `writePackedVarintList`, `writePackedEnumList`,
and `writePackedStringList` previously allocated a per-call
`std.Io.Writer.Allocating` to count bytes for the length prefix. The
size of every packed payload is computable up-front:

| Field type | Size formula | Cost |
|------------|-------------:|-----:|
| Fixed scalars (`fixed32`, `fixed64`, `float`, `double`, etc.) | `count × @sizeOf(elem)` | O(1) |
| Varint scalars (`int32`, `sint64`, etc.) | `Σ varintByteSize(item)` | O(N), no alloc |
| Enums (varint encoding) | `Σ varintByteSize(@bitCast(@intFromEnum(item)))` | O(N), no alloc |
| Strings/bytes | `Σ (varintByteSize(len) + len)` | O(N), no alloc |

The fast path replaces `alloc temp → encode-into-temp → memcpy →
free temp` with `walk-once-for-size → write-prefix → write-direct`.

**Why this doesn't hit the P-01 trap:** unlike `writeSubmessage` —
which would have its size pass recurse into nested submessages → each
their own size pass → exponential work — the packed-list writers
never recurse into another packed-list writer. Each list is
"flat" by definition (per protobuf spec: `packed=true` only applies
to scalar types), so the size walk is bounded by the list length.

Feature toggle: `-Duse-inline-packed-write=false` reverts to the
heap-temp-buffer behavior for both runtime and tests.

## Per-scenario A/B medians (10 rounds + 1 warmup, ReleaseSafe)

| Scenario | baseline (ns) | candidate (ns) | Δ | Status |
|----------|--------------:|---------------:|--:|--------|
| **dupe-fixture-vector-tile** | **4,706,157** | **4,233,022** | **−10.05%** | **improvement** |
| encode-fixture-vector-tile-roundtrip | 4,739,596 | 4,554,055 | −3.91% | neutral |
| decode-fixture-graphics-deep | 1,459,939 | 1,442,914 | −1.17% | neutral |
| json-decode-fixture-vector-tile | 6,620,203 | 6,585,969 | −0.52% | neutral |
| decode-fixture-vector-tile | 4,463,025 | 4,448,506 | −0.33% | neutral |
| decode-fixture-graphics | 1,493,492 | 1,492,056 | −0.10% | neutral |
| json-encode-fixture-vector-tile | 4,888,711 | 4,911,223 | +0.46% | neutral |
| (11 micro scenarios) | flat | flat | ±0–1.4% | all neutral |

### Why dupe wins so cleanly

`dupe` reads + re-encodes the entire vector_tile message tree. The
encode pass calls into the packed-list writers many times (once per
`Tile.Layer.features.geometry`, once per `Layer.keys`, etc.). Each
of those calls used to spin up a fresh `Allocating` writer; now they
write straight through. The alloc-pressure delta propagates through
the rest of `dupe` as reduced allocator-lock contention and reduced
GPA bookkeeping.

Sanity bench (5 rounds) measured **−27 % allocs/op on
encode-fixture-vector-tile-roundtrip** (10,545 vs 14,451). That
allocator-pressure win is what drives `dupe`'s 10 % timing gain.

### Why encode-roundtrip stays inside the gate

encode-roundtrip itself trends 3.91 % faster but doesn't clear the
variance gate. The signal is real (consistent direction, alloc count
is lower) — it just doesn't exceed `max(stddev × 3, 3 % × baseline)`.

### Where the signal stays flat

11 micro scenarios: none exercise packed-list writers (they bench
single-scalar encode/decode), so the optimization is a no-op for
those paths. Correct outcome.

## Stress follow-up

```
STRESS_FOLLOWUP result=PASS iterations=20
test=20/20 pass, bench=20/20 pass
```

## Acceptance

This optimization is **accepted**. Merge `perf/p-04-inline-packed-write`
(commit `1f47963`) into main.

## Rollback

```bash
zig build -Duse-inline-packed-write=false
```

Restores the heap-temp-buffer behavior verbatim.
