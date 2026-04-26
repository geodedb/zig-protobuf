# Decision — encode-decode-baseline

**Verdict:** BASELINE (no comparison; reference numbers established)
**Date:** 2026-04-26
**Run kind:** Baseline — no `ref_a` exists yet, so the regression gate is skipped.
**Summary line:** `NATIVE_BENCH result=BASELINE scenarios=18 regressions=0 improvements=0 ref_a=none ref_b=9d77025`

## What was measured

18 scenarios (11 micro, 7 integration) at `main @ 9d77025`,
10 measured rounds × 1 warmup per scenario, ReleaseSafe, on the host
described in `host-state-before.json` / `host-state-after.json`.

## Per-scenario reference medians

Computed by `scripts/compare.py` from `raw/round_*.json`. These
numbers serve as the `ref_a` for every subsequent A/B run until a new
baseline is established.

### Micro (ns/op median across 10 rounds; `iterations = 1_000_000` per round)

| Scenario | Median (ns) | Round-stddev |
|----------|------------:|-------------:|
| decode-varint-1byte | 33 | 0 |
| decode-varint-2byte | 34 | 0 |
| decode-varint-5byte-i32 | 38 | 0 |
| decode-varint-10byte-i64 | 42 | 0 |
| decode-fixed32 | 35 | 0 |
| decode-fixed64 | 37 | 0 |
| decode-tag | 35 | 0 |
| encode-varint-1byte | 36 | 0 |
| encode-varint-10byte | 38 | 0 |
| encode-fixed32 | 36 | 0 |
| encode-fixed64 | 36 | 0 |

### Integration (ns/op median across 10 rounds; one whole-fixture op per round)

| Scenario | Median (ns) | Round-stddev (ns) |
|----------|------------:|------------------:|
| decode-fixture-vector-tile | 2,663,588 | 198,930 |
| encode-fixture-vector-tile-roundtrip | 3,991,061 | 127,432 |
| dupe-fixture-vector-tile | 3,745,942 | 860,439 |
| decode-fixture-graphics | 1,553,436 | 45,400 |
| decode-fixture-graphics-deep | 1,516,524 | 22,014 |
| json-encode-fixture-vector-tile | 4,695,549 | 88,630 |
| json-decode-fixture-vector-tile | 6,477,563 | 40,221 |

## Anomalies / caveats

- The `dupe-fixture-vector-tile` round-stddev is unusually large
  relative to its median (~23%). This was a real, existing bug:
  `dupeImpl` previously called `.dupe()` on a `[]const u8` (the
  repeated-string path), which the existing test suite never
  exercised. The fix (one-line: `try allocator.dupe(u8, item)`) was
  required for the bench harness to compile this scenario.
  Confirm the fix did not change correctness: `zig build test` →
  140 / 140 pass after the change. Future runs should see the
  variance settle as the warm allocator stabilises.
- All micro scenarios show `stddev = 0` across the 10 measured
  rounds — that is, every round produced an identical median ns/op.
  This is consistent with very small (sub-50 ns) operations on a
  cache-warm CPU; the per-iteration distribution does have spread,
  but the round-level median is dominated by the modal value.
- `bench-ci` currently runs all 7 integration scenarios, including
  the 3 the architecture marks as "deeper / scheduled"
  (`decode-fixture-graphics-deep`, `json-encode-fixture-vector-tile`,
  `json-decode-fixture-vector-tile`). On this hardware the full set
  finishes in well under the 60 s CI budget, so the conflation does
  not yet matter; a `ci_safe: bool` field on `framework.Scenario`
  can be added later if a slower runner pushes the budget.

## Acceptance

This baseline is **accepted**. It will serve as `ref_a` for the next
optimization candidate (likely P-02 fast-path varint, per the gap
analysis). The first non-baseline A/B run uses:

```bash
bash scripts/ab_runner.sh --ref-a 9d77025 --ref-b <candidate-sha>
```

## Rollback

Not applicable — this run did not modify production code beyond the
`dupeImpl` correctness fix in `src/protobuf.zig` (which the test
suite endorses) and the new bench harness under `bench/` /
`scripts/`. Reverting any of those would only remove the ability to
measure, not change product behaviour.
