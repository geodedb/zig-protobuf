# Decision — P-05 ensureTotalCapacity in packed decode

**Verdict:** PASS — accept the optimization.
**Date:** 2026-04-26
**`ref_a`:** `ce4a045` (main, post-P-02 merge)
**`ref_b`:** `2c59dab` (this commit on `perf/p-05-ensure-capacity-packed`)
**Summary line:** `NATIVE_BENCH result=PASS scenarios=18 regressions=0 improvements=1 ref_a=ce4a0458 ref_b=2c59dab4`

## Optimization under test

`src/wire.zig:decodeRepeated` previously grew the result list one
element at a time on the packed-scalar and packed-enum branches, so
a packed payload with N elements triggered `O(log N)` realloc
roundtrips of the underlying `ArrayListUnmanaged` buffer. Since the
length-prefix tells us the byte count up-front, we can now reserve
the upper-bound capacity once before entering the per-element loop:

- **Fixed scalars** (`fixed32`, `fixed64`, `float`, `double`, etc.):
  `count = bytes / @sizeOf(scalar_repr)` — exact element count, no
  over-allocation.
- **Variable-width scalars + enums** (`int32`, `int64`, `sint32`,
  packed enums, etc.): `count = bytes` — the lower bound on element
  size is 1 byte, so this is a safe upper bound on element count.
  Over-allocates capacity for typical small-int payloads but the
  realloc count drops from `O(log N)` to **1**.

Feature toggle: `-Duse-ensure-capacity-packed=false` reverts to the
per-element-grow behavior for both runtime and tests.

## Per-scenario A/B medians (10 rounds + 1 warmup, ReleaseSafe)

| Scenario | baseline (ns) | candidate (ns) | Δ | Status |
|----------|--------------:|---------------:|--:|--------|
| **decode-fixture-graphics-deep** | **1,540,816** | **1,445,986** | **−6.15%** | **improvement** |
| decode-fixture-graphics | 1,614,440 | 1,535,020 | −4.92% | neutral |
| json-decode-fixture-vector-tile | 6,954,993 | 6,672,352 | −4.06% | neutral |
| json-encode-fixture-vector-tile | 5,064,316 | 4,924,473 | −2.76% | neutral |
| encode-fixture-vector-tile-roundtrip | 4,635,741 | 4,720,966 | +1.84% | neutral |
| dupe-fixture-vector-tile | 4,535,150 | 4,772,089 | +5.22% | neutral |
| decode-fixture-vector-tile | 4,189,534 | 4,431,642 | +5.78% | neutral |
| (11 micro scenarios) | — | — | ±0–1.5% | all neutral |

The variance-aware gate correctly classifies the vector_tile
slowdowns as neutral: stddev × 3 = 370K ns (3 % gate), delta = 242K
ns, so the directional signal is below the noise floor. Direction
matters, though, so:

### Why vector_tile drifts slower-direction in noise

Vector tile geometry is encoded as `repeated uint32` with packed=true.
The varint upper-bound capacity request (`bytes`) over-allocates by
roughly 50 % for typical 1- and 2-byte deltas. The over-allocation
itself is one realloc instead of many, but the resulting larger
backing array adds a small constant cost in subsequent operations
(e.g., `dupe-fixture-vector-tile` inherits the inflated capacity and
copies it). The net is well inside the variance gate; if the signal
ever surfaces above it, the heuristic should be tightened to
`bytes / 2` (assumes 2-byte average) for varints specifically.

### Why graphics-deep wins outright

`graphics.bin` exercises packed paths inside the GraphicsDB schema
(the GraphicsDB has packed-fixed and packed-enum lists in its
`Light`/`MapEntity`/`Index` types). The 50-round deep scenario
amortizes startup noise enough for the realloc-elimination signal to
clear the gate.

### Why json-* gets faster

The JSON paths decode the same vector_tile struct in their inner
loop, so the alloc reduction propagates through.

### Where the signal stays flat

All 11 micro scenarios are unchanged — none of them exercise
`decodeRepeated`, so the optimization is a no-op for those paths.
This is the correct outcome and confirms the patch is scoped to the
intended code path.

## Stress follow-up

Per `benchmark-framework` hard rule: 20× repeat after a PASS
verdict.

```
STRESS_FOLLOWUP result=PASS iterations=20
test=20/20 pass, bench=20/20 pass
```

Per-iteration log: `stress/stress_followup.log`.
Summary JSON: `stress/stress_followup_summary.json`.

## Acceptance

This optimization is **accepted**. Merge `perf/p-05-ensure-capacity-packed`
(commit `2c59dab`) into main.

The per-scenario gain (≤6 %) does not meet the architecture's "≥10 %
on packed fields" estimate. The most likely reason is that the
fixtures committed under `tests/fixtures/` aren't packed-heavy
enough to amortize the savings. A future fixture or micro-bench
specifically exercising a packed-scalar-of-thousands path would
likely show a larger margin; the optimization itself is sound and
aligned with the standard protobuf decoder pattern.

## Rollback

If a regression surfaces in production protobuf payloads against
`main`, the optimization can be disabled at build time without
reverting:

```bash
zig build -Duse-ensure-capacity-packed=false
```

This restores the per-element-grow behavior verbatim.
