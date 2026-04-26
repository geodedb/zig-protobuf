#!/usr/bin/env bash
# Exact command sequence used to produce this baseline evidence.
# Replay from the repo root at SHA 9d77025.

set -euo pipefail

OUT=docs/performance/2026-04-26-encode-decode-baseline
mkdir -p "$OUT/raw"

# Capture host state before the run.
BENCH_GIT_SHA=$(git rev-parse --short HEAD) \
    bash scripts/host_state.sh > "$OUT/host-state-before.json"

# Run the full CI bench (micro + integration), 10 measured rounds + 1 warmup.
BENCH_GIT_SHA=$(git rev-parse --short HEAD) \
    zig build bench-ci -Doptimize=ReleaseSafe -- \
        --rounds 10 --warmups 1 --out "$OUT/raw/"

# Capture host state after the run.
BENCH_GIT_SHA=$(git rev-parse --short HEAD) \
    bash scripts/host_state.sh > "$OUT/host-state-after.json"

# Aggregate per-round records into aggregate.json + emit the
# stable NATIVE_BENCH summary line on stdout.
python3 scripts/compare.py \
    --dir "$OUT/raw/" \
    --out "$OUT/aggregate.json"
