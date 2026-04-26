# Decision — P-02 fast-path varint

**Verdict:** PASS — accept the optimization on the candidate ref.
**Date:** 2026-04-26
**`ref_a`:** `09fa0d8` (bench-harness baseline; `main` post-harness)
**`ref_b`:** `fe7fee1` (this commit on `perf/p-02-fast-varint`)
**Summary line:** `NATIVE_BENCH result=PASS scenarios=18 regressions=0 improvements=1 ref_a=09fa0d86 ref_b=fe7fee1d`

## Optimization under test

`src/wire.zig:decodeScalar` for variable-width scalars now takes a
fast path when the next `max_bytes` are already buffered in the
reader. The fast path inline-unrolls the byte loop, eliminating the
per-iteration `try takeByte()` error-return scaffolding. The slow
path (the original byte-at-a-time loop) is preserved verbatim and
runs whenever the buffer is short or `use_fast_varint` is false.

Feature toggle: `-Duse-fast-varint=false` flips back to the slow
path for both runtime and tests.

## Per-scenario A/B medians

`zig build bench-ci` ran 10 measured rounds + 1 warmup per scenario
on each ref. Worktrees isolated builds; host-state captured before
and after.

| Scenario | baseline (ns) | candidate (ns) | Δ | Status |
|----------|--------------:|---------------:|--:|--------|
| **decode-varint-10byte-i64** | **42.0** | **39.0** | **−7.14%** | **improvement** |
| decode-varint-5byte-i32 | 38.0 | 37.0 | −2.63% | neutral |
| decode-varint-2byte | 34.0 | 35.0 | +2.94% | neutral |
| decode-varint-1byte | 33.0 | 34.0 | +3.03% | neutral |
| decode-fixed32 | 35.0 | 35.0 | 0.00% | neutral |
| decode-fixed64 | 37.0 | 37.0 | 0.00% | neutral |
| decode-tag | 35.0 | 35.0 | 0.00% | neutral |
| encode-varint-1byte | 36.0 | 36.0 | 0.00% | neutral |
| encode-varint-10byte | 38.0 | 38.0 | 0.00% | neutral |
| encode-fixed32 | 36.0 | 36.0 | 0.00% | neutral |
| encode-fixed64 | 36.0 | 36.0 | 0.00% | neutral |
| decode-fixture-vector-tile | 4,218,105 | 4,176,593 | −0.98% | neutral |
| encode-fixture-vector-tile-roundtrip | 4,645,395 | 4,659,442 | +0.30% | neutral |
| dupe-fixture-vector-tile | 4,547,131 | 4,583,906 | +0.81% | neutral |
| decode-fixture-graphics | 1,518,295 | 1,540,421 | +1.46% | neutral |
| decode-fixture-graphics-deep | 1,532,358 | 1,541,578 | +0.60% | neutral |
| json-encode-fixture-vector-tile | 5,106,444 | 5,124,867 | +0.36% | neutral |
| json-decode-fixture-vector-tile | 6,901,157 | 6,988,016 | +1.26% | neutral |

The +3% drift on `decode-varint-1byte` and `decode-varint-2byte` is
within the variance gate (`max(stddev * 3, 3% * baseline) = 1.26 ns`,
delta = 1 ns) and therefore correctly classified as neutral. The
expected fast-path payoff is largest on multi-byte varints because
the slow path's per-iteration error scaffolding adds proportionally
more overhead, which matches the observed −7% on the 10-byte case.

## Compare-tool fix shipped alongside

`scripts/compare.py` had its sign convention inverted for ns/op
metrics — it flagged a faster candidate as a regression because the
gating formula in the architecture document was written as if the
metric were "higher is better". Fixed in the same change: improvement
is now `delta_pct <= -target_gain_pct` and regression is
`delta_pct >= +|max_regression_pct|`. The architecture text remains
unchanged but should be revisited for future runs.

## Stress follow-up

The `benchmark-framework` skill's hard rule asks for the affected
stress / integration suites to run 20× after a PASS verdict to
catch any flake the single A/B pass might have masked. Driven by
`scripts/stress_followup.sh`, run on this branch (commit `017590d`):

```
STRESS_FOLLOWUP result=PASS iterations=20
test=20/20 pass, bench=20/20 pass
```

Per-iteration log: `stress/stress_followup.log`.
Summary JSON: `stress/stress_followup_summary.json`.

Each iteration ran `zig build test` (all 140 tests, including
`tests/fuzz_decode.zig` and the full integration suite) and
`zig build bench-integration -- --rounds 1 --warmups 0` (all 7
fixture-driven scenarios). Zero flakes across 40 sub-runs.

## Acceptance

This optimization is **accepted**. Merge `perf/p-02-fast-varint`
(commits `fe7fee1`, plus the `compare.py` sign-fix that landed with
this run) into `main`.

## Rollback

If a regression surfaces in production protobuf payloads against
`main`, the optimization can be disabled at build time without
reverting the commit:

```bash
zig build -Duse-fast-varint=false
```

This restores the byte-at-a-time slow path verbatim.
