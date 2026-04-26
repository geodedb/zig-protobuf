# Methodology — encode-decode-baseline

**Date:** 2026-04-26
**Repo:** devnw/zig/protobuf
**Baseline ref:** `main` @ 9d77025
**Run kind:** Baseline (no prior history; gate logic skipped, all medians written as reference numbers)

---

## Hardware / OS / Toolchain

Captured live by `scripts/host_state.sh` into `host-state-before.json`
and `host-state-after.json`. Headline values from this run:

| Field | Value |
|-------|-------|
| OS | Linux (Debian 13 kernel 6.12.74) |
| CPU | Intel Xeon E5-2680 v4 @ 2.40 GHz |
| Cores | 56 |
| RAM | 256 GB |
| Zig | 0.16.0 |
| Optimize mode | ReleaseSafe |
| CPU pinning | none (host has 56 cores; bench scenarios are single-threaded) |
| Scaling governor | schedutil |

ReleaseFast is the preferred optimize mode but Zig 0.16.0 emits an ICE
on the bench executable under ReleaseFast (see `build.zig:194-198` and
`architecture.md` §9). ReleaseSafe is the mandated floor for this run.

## Bench layout

Three layers, all driven by repo-native `zig build` steps:

| Layer | Build step | Scenarios | Rounds × Warmups | Notes |
|-------|-----------|-----------|------------------|-------|
| Micro | `zig build bench-micro` | 11 | 10 × 1 | Deterministic byte-literal inputs, zero-alloc probes, 1 M inner iterations per round |
| Integration | `zig build bench-integration` | 7 | 5 × 1 (this run forced 10×1) | Real fixture binaries from `tests/fixtures/`, allocator active, alloc counts captured |
| Comparison | `bash scripts/ab_runner.sh` | (driven externally) | n/a | Worktree-based A/B; not used on a baseline run |

This baseline run uses `zig build bench-ci -- --rounds 10 --warmups 1`
which dispatches both layers under one binary. 18 scenarios total
(comparison scenarios are AB-only and never come through the CLI).

## Per-iteration timing

`std.Io.Clock.Timestamp.now(io, .awake)` (the monotonic clock) is
sampled before and after each inner iteration of the timed loop. The
elapsed nanoseconds are stored in a per-iteration sample buffer; round
metrics (median, p50/p95/p99, stddev, min, max) are computed at the
end of the round. `std.time.Instant` and `std.time.Timer` were both
removed in Zig 0.16.0; `Io.Clock` is the only stdlib cross-platform
high-resolution timer available in this toolchain.

## Zero-alloc probes

Every micro scenario carries `zero_alloc_expected: true`. The harness
wraps the backing allocator in `framework.CountingAllocator` (a small
vtable wrapper that tallies bytes alloc'd / freed) and asserts
`alloc_delta_bytes == 0` after each measured round. A non-zero net
heap delta on a zero-alloc scenario causes `std.process.exit(1)` with
a clear FATAL message, which propagates through the build step and
fails CI.

Integration scenarios run with the allocator unmistructed; the bench
records `alloc_delta_bytes` and `allocs_per_op` so that future runs
can detect alloc-count regressions even though they don't gate on a
zero contract.

## Dead-code-elimination guard

`framework.sink(comptime T, v)` (a `noinline` wrapper around
`std.mem.doNotOptimizeAway`) is invoked on every hot-path result so
the optimizer cannot eliminate the timed body. Without it, the
compiler aggressively folds the loop in ReleaseSafe mode and the
measured ns/op collapse to noise.

## Reproducibility

All commands used to produce this run are recorded in `commands.sh`.
The exact bench source is at `bench/{main,framework,scenarios_*}.zig`
in the repo at SHA `9d77025`. The fixture binaries
(`tests/fixtures/{vector_tile,graphics}.bin`) are checked into the
repo and read read-only.

## Threshold context (for future A/B runs)

The baseline run does not gate on these, but they are the values
`scripts/compare.py` will apply once a candidate ref exists:

| Threshold | Value |
|-----------|-------|
| target_gain_pct | 5.0 |
| max_regression_pct | -3.0 |
| variance_gate_multiplier | 3.0 (× baseline stddev) |
| fixed_floor_pct | 3.0 (% of baseline median) |

Effective regression gate is `max(stddev * 3, baseline * 0.03)` —
whichever is larger guards against false positives from a single
noisy round.
