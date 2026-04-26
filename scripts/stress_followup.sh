#!/usr/bin/env bash
# 20x stress follow-up — run the test suite + the integration bench
# repeatedly and fail loudly if any single iteration deviates from the
# previous one.
#
# This is the "accepted-optimization stress" hard rule from the
# native-benchmarks methodology (benchmark-framework skill, A/B
# protocol step 8): once an A/B run produces a PASS, the affected
# stress/integration suites must run 20x consecutively without any
# flake before the optimization can ship.
#
# Usage:
#   bash scripts/stress_followup.sh [--iterations 20] [--out <dir>]
#
# Outputs:
#   <out>/stress_followup.log           per-iteration summary
#   <out>/stress_followup_summary.json  pass/fail counts
#
# Stdlib only (bash + zig + python3).

set -uo pipefail

ITERATIONS=20
OUT_DIR="docs/performance/$(date -u +%F)-stress-$(git rev-parse --short HEAD)"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --iterations) ITERATIONS=$2; shift 2;;
        --out)        OUT_DIR=$2; shift 2;;
        -h|--help)
            sed -n '2,21p' "$0"
            exit 0;;
        *) echo "stress_followup: unknown arg: $1" >&2; exit 2;;
    esac
done

mkdir -p "$OUT_DIR"
LOG="$OUT_DIR/stress_followup.log"
: > "$LOG"

test_pass=0
test_fail=0
bench_pass=0
bench_fail=0

trap 'echo "stress_followup: interrupted at iteration $i" >&2; exit 130' INT TERM

echo "stress_followup: $ITERATIONS iterations, ref=$(git rev-parse --short HEAD)" | tee -a "$LOG"

for ((i = 1; i <= ITERATIONS; i++)); do
    echo "=== iter $i / $ITERATIONS ===" | tee -a "$LOG"

    if zig build test 2>&1 | tail -3 >> "$LOG"; then
        test_pass=$((test_pass + 1))
    else
        test_fail=$((test_fail + 1))
        echo "iter $i: zig build test FAILED" | tee -a "$LOG"
    fi

    # Single-round bench-integration. We only care about runtime
    # stability (no panics, no fixture-load errors, no zero-alloc
    # contract violations on the integration scenarios that have
    # them), not the timing numbers.
    bench_dir="$OUT_DIR/bench-iter-$(printf '%02d' "$i")"
    mkdir -p "$bench_dir"
    if BENCH_GIT_SHA="stress$i" zig build bench-integration -Doptimize=ReleaseSafe -- \
            --rounds 1 --warmups 0 --out "$bench_dir/raw/" >> "$LOG" 2>&1; then
        bench_pass=$((bench_pass + 1))
    else
        bench_fail=$((bench_fail + 1))
        echo "iter $i: bench-integration FAILED" | tee -a "$LOG"
    fi
done

cat > "$OUT_DIR/stress_followup_summary.json" <<EOF
{
  "ref": "$(git rev-parse --short HEAD)",
  "iterations": $ITERATIONS,
  "test_pass": $test_pass,
  "test_fail": $test_fail,
  "bench_pass": $bench_pass,
  "bench_fail": $bench_fail,
  "timestamp_utc": "$(date -u +%FT%TZ)"
}
EOF

echo "" | tee -a "$LOG"
echo "stress_followup: test=$test_pass/$ITERATIONS pass, bench=$bench_pass/$ITERATIONS pass" | tee -a "$LOG"
echo "stress_followup: log at $LOG" | tee -a "$LOG"
echo "stress_followup: summary at $OUT_DIR/stress_followup_summary.json" | tee -a "$LOG"

if [[ $test_fail -gt 0 || $bench_fail -gt 0 ]]; then
    echo "STRESS_FOLLOWUP result=FAIL test_fail=$test_fail bench_fail=$bench_fail"
    exit 1
fi
echo "STRESS_FOLLOWUP result=PASS iterations=$ITERATIONS"
