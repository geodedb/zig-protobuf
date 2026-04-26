# Benchmark Architecture: encode-decode-baseline
**Date:** 2026-04-26
**Repo:** devnw/zig/protobuf
**Baseline ref:** `main` @ 9d77025
**Zig version:** 0.16.0

---

## 1. Goal

This benchmark run establishes a quantitative performance baseline for the seven
hot paths the audit identified as not yet measured, and installs permanent
regression guards for the two paths (P-07 encode-scalar stack-buffered, P-10
dupe initCapacity) that are already closed.

**Targeted hotspots and expected first-run gains (after subsequent optimization
passes):**

| Gap ID | Function | File:Line | Expected gain once optimization lands |
|--------|----------|-----------|----------------------------------------|
| P-02 | `decodeScalar` varint byte-at-a-time | wire.zig:262 | ≥15% ns/op on hot varint sizes |
| P-03 | `decodeMessage` inline-for tag dispatch | wire.zig:575 | ≥10% ns/op on small messages |
| P-01 | `writeSubmessage` 2-pass alloc-then-write | protobuf.zig:275 | ≥20% ns/op; alloc elimination |
| P-04 | `writePackedFixedList` / `writePackedVarintList` temp buffers | protobuf.zig:291-400 | ≥15% ns/op |
| P-05 | `decodeRepeated` packed loop missing ensureTotalCapacity | wire.zig:458 | ≥10% ns/op on packed fields |
| P-08 | `json.parse` key dispatch O(N²) | json.zig:43 | ≥25% ns/op on wide messages |
| P-09 | `json.encode` value-tree round-trip | json.zig:133 | ≥10% ns/op |
| P-07 | encode-scalar stack-buffered (closed) | — | regression guard only |
| P-10 | dupe initCapacity (closed) | — | regression guard only |

On the first run (this baseline run) there is no prior data; all scenarios
produce reference numbers rather than pass/fail gate results. The A/B gate
activates on the next optimization branch where the baseline ref is `main`
@ 9d77025.

**Target gain threshold (post-optimization):** ≥5.0% improvement in median
`ns_per_op` to claim a scenario as a win.

**Regression floor:** −3.0% in median `ns_per_op` triggers a CI failure. Because
no historical data exists yet, this floor is soft (advisory) on the first run
and becomes a hard gate from the first comparison run onward.

---

## 2. Scope

### Layer definitions

**Micro layer** — single hot-path invocations with deterministic, hand-crafted
inputs. No allocator is touched by the hot path in zero-alloc scenarios. Each
scenario runs in a tight loop (`--rounds 10`, `--warmups 1` by default, `--rounds
100` for the deeper suite). Target total wall time ≤ 60 s on CI hardware.

**Integration layer** — whole-message encode/decode against the real fixture
binaries already present in the repo (`tests/fixtures/`). Exercises the full
decode pipeline including tag dispatch, repeated fields, submessage recursion,
and the security caps. Two sub-tiers:

- *CI-safe* (`bench-ci`) — 4 scenarios, ≤ 60 s total; always runs in the `bench`
  CI stage.
- *Deeper* (`bench-integration`) — 3 additional tail-latency and JSON scenarios;
  scheduled or triggered manually; no wall-time cap in CI.

**Comparison layer** — a single aggregation scenario driven by `bench-ab` and
`scripts/compare.py`. Consumes the raw JSON output from the micro and
lightweight integration scenarios and emits a single `aggregate.json` plus the
stable `NATIVE_BENCH ...` summary line read by CI. Not executed in isolation;
driven entirely by `scripts/ab_runner.sh`.

### Scenarios per layer

#### Micro — CI-safe (11 scenarios)

All micro scenarios are single-threaded (`N=1`). Deterministic byte-literal
inputs. `--rounds 10 --warmups 1` default.

1. `decode-varint-1byte` — input `0x01`; zero-alloc
2. `decode-varint-2byte` — input `0xAC 0x02`; zero-alloc
3. `decode-varint-5byte-i32` — input `0xFF 0xFF 0xFF 0xFF 0x0F` (max uint32); zero-alloc
4. `decode-varint-10byte-i64` — input 10-byte max int64 varint; zero-alloc
5. `decode-fixed32` — 4-byte LE literal; zero-alloc
6. `decode-fixed64` — 8-byte LE literal; zero-alloc
7. `decode-tag` — 1-byte tag `(1 << 3) | 0`; zero-alloc
8. `encode-varint-1byte` — encodes `u64(1)`; zero-alloc (P-07 regression guard)
9. `encode-varint-10byte` — encodes `u64(0xFFFF_FFFF_FFFF_FFFF)`; zero-alloc
10. `encode-fixed32` — encodes `f32(1.0)`; zero-alloc
11. `encode-fixed64` — encodes `f64(1.0)`; zero-alloc

#### Integration — CI-safe (4 scenarios)

`--rounds 5 --warmups 1`. Allocator is active; alloc counts captured.

12. `decode-fixture-vector-tile` — `tests/fixtures/vector_tile.bin` (125 KB)
13. `encode-fixture-vector-tile-roundtrip` — decode then re-encode the same fixture
14. `dupe-fixture-vector-tile` — deep clone via `dupe`; P-10 regression guard
15. `decode-fixture-graphics` — `tests/fixtures/graphics.bin` (1.1 MB); may
    exceed 60 s budget on slow CI runners, in which case it is promoted to the
    deeper suite automatically (the runner script checks elapsed time and moves
    the result file to `raw/deeper/` if wall time > 30 s per round)

#### Integration — deeper / scheduled (3 scenarios)

`--rounds 50 --warmups 2`. Yields p95/p99 tail-latency data.

16. `decode-fixture-graphics-deep` — 50 rounds of the 1.1 MB graphics fixture
17. `json-encode-fixture-vector-tile` — JSON encode of decoded vector_tile; P-09 baseline
18. `json-decode-fixture-vector-tile` — JSON decode of a serialized vector_tile; P-08 baseline

#### Comparison (1 aggregation entry)

19. `encode-decode-baseline-comparison` — A/B basket covering scenarios 1-15.
    Driven by `bench-ab`. Not a standalone bench executable invocation.

---

## 3. Result schema usage

Every scenario emits one JSON file per round into `raw/round_<N>.json`. The
schema is shared across all languages (Zig is the only language in this repo,
but the schema is written to be forward-compatible with Go or C additions).

```json
{
  "schema_version": "1",
  "run_id": "<date>-<slug>-<sha8>",
  "scenario_id": "decode-varint-1byte",
  "layer": "micro",
  "language": "zig",
  "round": 1,
  "warmup": false,
  "iterations": 1000000,
  "ns_per_op_median": 0.0,
  "ns_per_op_p50": 0.0,
  "ns_per_op_p95": 0.0,
  "ns_per_op_p99": 0.0,
  "ns_per_op_stddev": 0.0,
  "alloc_delta_bytes": 0,
  "allocs_per_op": 0,
  "bytes_per_op": 0,
  "zero_alloc_observed": true,
  "zero_alloc_expected": true,
  "alloc_assertion_passed": true,
  "input_bytes": 1,
  "host_sha": "9d77025",
  "host_os": "linux",
  "host_cpu_model": "",
  "host_mem_kb": 0,
  "timestamp_utc": ""
}
```

**Field notes:**

- `ns_per_op_*` fields are computed across iterations within a single round.
  `scripts/compare.py` aggregates across rounds to produce cross-round p50/p95/p99.
- `alloc_delta_bytes` is the total bytes requested from the counting allocator
  during the timed loop (excluding warmup iterations). For zero-alloc scenarios
  this must be 0.
- `alloc_assertion_passed` is set to `false` and the process exits non-zero if
  `zero_alloc_expected` is `true` and `alloc_delta_bytes > 0`.
- `bytes_per_op` is input payload size (for integration scenarios: fixture file
  size).
- Warmup rounds are written to `raw/warmup_<N>.json` and excluded from
  aggregation.

---

## 4. Repo-native commands

New `zig build` steps to be added to `build.zig` by `/native-benchmarks:implement`.
The prefix matches the repo's existing `bench` step.

| Step name | Description | Optimize mode | Wall-time budget |
|-----------|-------------|---------------|------------------|
| `bench` | Existing smoke step (unchanged) | ReleaseSafe | n/a |
| `bench-micro` | Micro layer only | ReleaseSafe¹ | ≤ 60 s |
| `bench-integration` | Both integration tiers | ReleaseSafe¹ | unlimited (scheduled) |
| `bench-ci` | Micro + CI-safe integration | ReleaseSafe¹ | ≤ 60 s |
| `bench-smoke` | Single-round smoke over all scenarios (no output files) | ReleaseSafe¹ | ≤ 30 s |

¹ ReleaseSafe is the mandated floor for Zig 0.16.0 due to a compiler ICE on
ReleaseFast for the bench executable (confirmed in `build.zig:194-198`). A
`// TODO: retry ReleaseFast on next Zig point release` comment must appear in
`build.zig` at the bench exe definition.

Supporting scripts (not `zig build` steps):

| Script | Language | Purpose |
|--------|----------|---------|
| `scripts/compare.py` | Python 3.10+ stdlib | Read `raw/round_*.json`, compute medians / p95 / p99 / stddev, emit `aggregate.json` + `NATIVE_BENCH` summary line |
| `scripts/ab_runner.sh` | bash | Worktree-based A/B, captures host state, invokes `bench-ci` on both refs |
| `scripts/host_state.sh` | bash | Reads `/proc/cpuinfo`, `/proc/meminfo`, `uname -a`; degrades gracefully on macOS/BSD |

The command names `bench-ab` and `bench-compare` in the plan refer to these
scripts; there is no separate `zig build bench-ab` step.

---

## 5. A/B protocol

### Baseline ref policy

- Baseline ref: `main` @ 9d77025.
- Every A/B run must record `ref_a` (baseline SHA) and `ref_b` (candidate SHA)
  in `ab_run_meta.json`.
- `ab_runner.sh` refuses with exit 1 if `ref_a == ref_b` (identical SHAs would
  produce meaningless comparison noise).
- Both refs are checked out into separate git worktrees under
  `docs/performance/ab-worktrees/` so the working tree is never dirty during
  measurement. Worktrees are removed after the run completes.

### Warmup and round counts

| Suite | Warmup rounds | Measurement rounds | Stress multiplier |
|-------|---------------|-------------------|-------------------|
| CI (`bench-ci`) | 1 | 10 | 20× |
| Deeper (`bench-integration`) | 2 | 50 | 20× |
| Smoke (`bench-smoke`) | 0 | 1 | 1× |

The stress multiplier means the bench binary runs each scenario for
`iterations = base_iterations × stress_multiplier`. For micro scenarios
`base_iterations = 50_000`, so a full CI run executes 1_000_000 iterations per
scenario per round.

### Host isolation

Before starting `ref_a` measurements, `host_state.sh` records system state to
`ab_run_meta.json`. The same snapshot is taken after `ref_b` completes. A
significant difference in `/proc/loadavg` between the two snapshots is logged
as a warning in `aggregate.json` but does not fail the run. CPU pinning via
`taskset -c 0` is recommended on Linux CI runners and is noted in `bench-ab`
usage docs; it is not enforced because GitLab shared runners may not support it.

---

## 6. Gating

### Variance-aware threshold formula

For each scenario `s`, define:

```
baseline_median  = p50 across all ref_a rounds
candidate_median = p50 across all ref_b rounds
delta_pct        = (candidate_median - baseline_median) / baseline_median × 100

stddev_a         = stddev across ref_a rounds
variance_gate    = stddev_a × variance_gate_multiplier   (default: 3.0×)
fixed_floor_pct  = 3.0   (absolute minimum detectable change)

effective_gate   = max(variance_gate, fixed_floor_pct × baseline_median / 100)
```

A result is **REGRESSION** if `delta_pct < −3.0` AND
`|candidate_median − baseline_median| > effective_gate`.

A result is **IMPROVEMENT** if `delta_pct ≥ 5.0` AND the magnitude exceeds the
effective gate (prevents noise from being reported as a win).

A result is **NEUTRAL** otherwise.

The effective gate prevents a single noisy round from triggering a false
regression. The fixed floor of 3.0% prevents tiny absolute differences on
very-fast paths (sub-nanosecond) from ever gating CI.

### CI gate placement

The gate runs as part of `scripts/compare.py --gate`. The script exits 0 if all
scenarios are NEUTRAL or IMPROVEMENT. It exits 1 if any scenario is REGRESSION.

### Stable one-line summary

`scripts/compare.py` always writes exactly one line matching this pattern to
stdout so CI log scrapers can find it:

```
NATIVE_BENCH result=<PASS|FAIL> scenarios=<N> regressions=<N> improvements=<N> ref_a=<sha8> ref_b=<sha8>
```

This line is also written into `aggregate.json` as the `summary_line` field.

On the **baseline run** (no prior data, no `ref_a`), `compare.py` emits:

```
NATIVE_BENCH result=BASELINE scenarios=<N> regressions=0 improvements=0 ref_a=none ref_b=<sha8>
```

---

## 7. Cross-platform coverage

### Primary platform

Linux x86-64 is the primary CI platform (confirmed by `.gitlab-ci.yml` using
`debian:bookworm-slim` image). All micro and integration scenarios must pass
here.

### Smoke platform coverage

`bench-smoke` (single-round, no output files) must be validated on:

| Platform | Trigger |
|----------|---------|
| Linux x86-64 | Every CI run |
| macOS arm64 (Apple Silicon) | Manual / scheduled |
| macOS x86-64 | Manual (legacy) |
| Windows x86-64 | Out of scope for this design (no Windows CI configured) |

Platform-specific code paths in this library are limited to the `freestanding`
target guard in `wire.zig:6-12` (log stub). No OS-specific hot paths exist in
the encode/decode core; therefore platform-specific scenario variants are not
required beyond the smoke check.

### CPU pinning conventions

On Linux:

```bash
taskset -c 0 zig build bench-ci -- --out raw/
```

On macOS, `taskset` is not available. The runner script logs a warning and
proceeds without pinning. Variance on macOS is expected to be higher; the
variance gate multiplier may need to be raised to 5.0 for macOS runs.

---

## 8. Evidence policy

### Directory layout

Each dated run produces a self-contained directory:

```
docs/performance/
  2026-04-26-encode-decode-baseline/
    architecture.md          (this file)
    plan.json
    raw/
      round_01.json          (one file per measurement round, per scenario)
      round_02.json
      ...
      warmup_01.json
      deeper/                (deeper-suite rounds, if run)
        round_01.json
        ...
    aggregate.json           (produced by scripts/compare.py)
    ab_run_meta.json         (produced by scripts/ab_runner.sh when A/B is run)
    decision.md              (human-authored: ACCEPT / REJECT / DEFER + rationale)
    rollback.md              (present only if the run triggers a rollback action)
```

### Retention

- Raw round files and aggregate JSON are committed to the repo under
  `docs/performance/`. The dated directory is immutable after the run closes.
- `decision.md` must be written before the feature branch is merged.
- If a rollback is required, `rollback.md` documents the reverted commit SHA
  and the scenario that triggered it.

### Baseline run special case

The first run (`2026-04-26-encode-decode-baseline`) has no `ref_a`. The
`ab_run_meta.json` records `ref_a: null` and `baseline: true`. `compare.py`
skips the gate logic and writes all scenario medians to `aggregate.json` as
reference numbers. All future A/B runs load this `aggregate.json` as their
baseline when `--baseline-dir` is not explicitly specified.

---

## 9. Risks and language-specific caveats

### Zig 0.16.0 — `std.time.Timer` removed

`std.time.Timer` no longer exists in Zig 0.16.0. The bench harness must use
`std.time.Instant`:

```zig
const t0 = try std.time.Instant.now();
// ... timed work ...
const elapsed_ns = (try std.time.Instant.now()).since(t0);
```

`Instant.since` returns `u64` nanoseconds. This is the only supported
cross-platform high-resolution timer in Zig 0.16.0.

### Zig 0.16.0 — ReleaseFast ICE

`build.zig:194-198` already documents the ICE. The bench exe is built at
ReleaseSafe. This is acceptable for baseline measurements provided the same
optimize mode is used for both `ref_a` and `ref_b` in every A/B run. A TODO
must be added for a ReleaseFast retry on the next Zig point release.

### Dead-code elimination

Zig's optimizer will eliminate bench loop bodies whose results are unused. The
harness must use `std.mem.doNotOptimizeAway` (available in `std.mem` as of Zig
0.14+) or a `noinline` sink function to prevent this. Example:

```zig
noinline fn sink(v: anytype) void {
    std.mem.doNotOptimizeAway(v);
}
```

Call `sink(result)` after every hot-path invocation inside the timing loop.

### Counting allocator for zero-alloc probes

Zig's standard library does not ship a counting allocator. The bench harness
must implement a thin wrapper `CountingAllocator` that records `total_bytes`
and `alloc_count` and wraps `std.heap.GeneralPurposeAllocator`. On each
zero-alloc scenario, the harness asserts `counting_alloc.total_bytes == 0`
after the timing loop and fails the process if the assertion is violated. This
is the `alloc_probe` mechanism referenced in `plan.json`.

### GC / JIT noise

Not applicable to Zig; there is no GC or JIT. However:

- The security caps (`max_decode_depth`, `max_decode_alloc_per_field`,
  `max_decode_elements`, `max_dupe_depth`) must remain active in all bench
  scenarios to measure representative production behaviour. Disabling them for
  bench would inflate numbers relative to real workloads.
- The `comptime` tag-dispatch table in `decodeMessage` (wire.zig:617) means
  the inline for loop is fully unrolled at compile time. Measuring P-03 in
  isolation requires a message type with enough fields that the unrolled table
  is non-trivial; the vector_tile fixture serves this purpose.

### Fixture integrity

The fixture binaries (`tests/fixtures/graphics.bin`, `tests/fixtures/vector_tile.bin`)
are not generated during the build. The bench harness must verify their
presence before starting and return a clear error if missing (rather than
panicking mid-run). The harness must not modify the fixture files.

### `@setEvalBranchQuota`

`json.zig:16` and `json.zig:141` both set a branch quota of 1_000_000. The
bench binary is compiled with the same quota. This does not affect runtime
performance but it does mean the JSON scenarios cannot use message types that
exceed this quota.

### A/B feature-flag contract

Every optimization covered by this plan must expose either:

- A **compile-time switch** (e.g., `comptime use_fast_varint: bool = true`) that
  can be toggled to `false` to re-enable the old path; OR
- A **build option** (e.g., `-Duse-fast-varint=false`) passed through `build.zig`.

This is required to confirm that the bench delta is caused by the optimization
and not by unrelated environmental variance. The A/B runner must support a
`--disable-flag <name>` argument that sets the relevant build option to its
off-state for the `ref_b` run.

---

## Implementation notes (for `/native-benchmarks:implement`)

These notes are design constraints, not source code. They are addressed to the
implementer.

### Bench binary CLI

The bench binary (`bench/main.zig`) must accept:

```
zig build bench-micro -- --scenario <id> --rounds <N> --warmups <N> --out <dir> [--iterations <N>]
```

- `--scenario` selects one scenario from the compiled-in list. If omitted, all
  scenarios for the step run in sequence.
- `--rounds` sets measurement round count (default: 10 for bench-micro, 5 for
  bench-integration).
- `--warmups` sets warmup round count (default: 1).
- `--out` sets the output directory for `round_*.json` files (default: `raw/`).
- `--iterations` overrides the per-round iteration count (default: 1_000_000
  for micro, 1 for integration).

### Timer

Use `std.time.Instant.now()` and `.since()` for all timing. Do not use
`std.os.clock_gettime` directly; it is not available on all Zig targets.

### Dead-code elimination guard

Implement as a `noinline fn sink(comptime T: type, v: T) void` calling
`std.mem.doNotOptimizeAway(v)`. Call after every hot-path result inside the
timing loop.

### Counting allocator

Implement `CountingAllocator` as a struct wrapping any `std.mem.Allocator`,
intercepting `alloc`, `resize`, and `free` to accumulate byte counts. Provide
`reset()` to clear counters between rounds.

### JSON output

Use `std.json.stringify` (or manual `std.io.Writer` writing) to emit one
`round_N.json` file per round. File names are zero-padded to three digits
(`round_001.json`).

### `scripts/compare.py`

Use Python 3.10+ stdlib only (`json`, `statistics`, `pathlib`, `argparse`,
`sys`). No third-party packages. Read all `round_*.json` from `--dir`, compute
per-scenario medians, emit `aggregate.json`, print `NATIVE_BENCH ...` line to
stdout. Accept `--gate` flag to apply the regression check (exit 1 on failure).
Accept `--baseline-dir` to specify a different baseline run directory.

### `scripts/ab_runner.sh`

Use `git worktree add` / `git worktree remove`. Refuse if
`git rev-parse ref_a == git rev-parse ref_b`. Run `host_state.sh` before
`ref_a` measurement and after `ref_b` measurement. Capture both outputs into
`ab_run_meta.json`. Pass `--out raw/ref_a/` and `--out raw/ref_b/` to the bench
binary for each ref. Invoke `compare.py` with `--gate` at the end and propagate
its exit code.

### `scripts/host_state.sh`

On Linux: read `/proc/cpuinfo` (model name, core count), `/proc/meminfo`
(MemTotal), `uname -a`, `/proc/loadavg`. On macOS: use `sysctl` equivalents
(`sysctl -n machdep.cpu.brand_string`, `sysctl -n hw.memsize`). Output a single
JSON object to stdout.

### GitLab CI `bench` stage

Do NOT modify `.gitlab-ci.yml` in this step. The proposed addition is:

```yaml
bench:
  stage: bench
  script:
    - zig build bench-ci -- --out docs/performance/runs/$(date +%F)/raw/
    - python3 scripts/compare.py --dir docs/performance/runs/$(date +%F)/raw/ --gate
  artifacts:
    paths:
      - docs/performance/runs/
```

This job definition is to be added by `/native-benchmarks:implement` or a
subsequent CI-configuration command. The `bench` stage must be inserted after
`test` in the `stages` list.

---

Next steps:
1. /native-benchmarks:implement --plan docs/performance/2026-04-26-encode-decode-baseline/plan.json
2. /native-benchmarks:run-ab --ref-a 9d77025 --ref-b HEAD
3. /native-benchmarks:compare and /native-benchmarks:report close out the run.
