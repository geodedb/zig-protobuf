#!/usr/bin/env bash
# A/B benchmark runner — builds two distinct artifacts from two
# distinct git refs, captures host state before and after, runs
# alternating measured rounds, and produces per-round JSON records
# that scripts/compare.py can aggregate.
#
# Implements the protocol from
# docs/performance/2026-04-26-encode-decode-baseline/architecture.md
# section 5 and the ab-runner skill (worktree-based isolation, refuse
# identical refs, fail loud, retain raw samples).
#
# Usage:
#   scripts/ab_runner.sh \
#       --ref-a <baseline-sha-or-branch> \
#       --ref-b <candidate-sha-or-branch> \
#       [--rounds 10] [--warmups 1] \
#       [--out docs/performance/<date>-<slug>/]
#
# Hard rules enforced here:
# - refuses if rev-parse(ref_a) == rev-parse(ref_b)
# - refuses if either worktree has uncommitted changes after creation
# - captures host_state.sh output before and after the run
# - runs warmup once per ref, then alternating measured rounds
# - leaves raw/, host-state-*.json, commands.sh, ab_run_meta.json behind

set -euo pipefail

REF_A=""
REF_B=""
ROUNDS=10
WARMUPS=1
OUT_DIR=""
WORKTREE_BASE="docs/performance/ab-worktrees"
DISABLE_FLAG=""

usage() {
    cat <<EOF
Usage: $(basename "$0") --ref-a <ref> --ref-b <ref> [options]

Required:
  --ref-a <ref>            Baseline ref (branch, tag, or SHA).
  --ref-b <ref>            Candidate ref (must differ from --ref-a).

Options:
  --rounds <N>             Measured rounds per variant (default: 10).
  --warmups <N>            Warmup rounds per variant (default: 1).
  --out <dir>              Run directory; raw/ goes inside this.
                           Default: docs/performance/<date>-ab-<sha>/.
  --disable-flag <name>    Pass -D<name>=false to ref_b's bench build.
                           Used to A/B-disable an optimization toggle.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ref-a)        REF_A=$2; shift 2;;
        --ref-b)        REF_B=$2; shift 2;;
        --rounds)       ROUNDS=$2; shift 2;;
        --warmups)      WARMUPS=$2; shift 2;;
        --out)          OUT_DIR=$2; shift 2;;
        --disable-flag) DISABLE_FLAG=$2; shift 2;;
        -h|--help)      usage; exit 0;;
        *) echo "ab_runner: unknown arg: $1" >&2; usage; exit 2;;
    esac
done

if [[ -z "$REF_A" || -z "$REF_B" ]]; then
    echo "ab_runner: --ref-a and --ref-b are required" >&2
    usage
    exit 2
fi

# Resolve refs to actual SHAs to detect the identical-ref case.
SHA_A=$(git rev-parse --verify "$REF_A^{commit}" 2>/dev/null || true)
SHA_B=$(git rev-parse --verify "$REF_B^{commit}" 2>/dev/null || true)

if [[ -z "$SHA_A" ]]; then
    echo "ab_runner: cannot resolve ref-a='$REF_A'" >&2
    exit 2
fi
if [[ -z "$SHA_B" ]]; then
    echo "ab_runner: cannot resolve ref-b='$REF_B'" >&2
    exit 2
fi
if [[ "$SHA_A" == "$SHA_B" ]]; then
    echo "ab_runner: refusing — ref_a and ref_b resolve to the same SHA ($SHA_A)" >&2
    exit 1
fi

# Resolve repo root.
REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$REPO_ROOT"

if [[ -z "$OUT_DIR" ]]; then
    DATE=$(date -u +%F)
    OUT_DIR="docs/performance/${DATE}-ab-${SHA_A:0:7}-${SHA_B:0:7}"
fi
mkdir -p "$OUT_DIR/raw/ref_a"
mkdir -p "$OUT_DIR/raw/ref_b"

WORKTREE_A="$WORKTREE_BASE/wt-a-${SHA_A:0:7}"
WORKTREE_B="$WORKTREE_BASE/wt-b-${SHA_B:0:7}"

# Cleanup helpers.
cleanup() {
    local code=$?
    set +e
    git worktree remove --force "$WORKTREE_A" 2>/dev/null || true
    git worktree remove --force "$WORKTREE_B" 2>/dev/null || true
    exit "$code"
}
trap cleanup EXIT INT TERM

echo "ab_runner: ref_a=$SHA_A ref_b=$SHA_B" >&2
echo "ab_runner: out=$OUT_DIR" >&2

# Create worktrees from the resolved SHAs in detached state.
git worktree add --detach "$WORKTREE_A" "$SHA_A" >/dev/null
git worktree add --detach "$WORKTREE_B" "$SHA_B" >/dev/null

# Verify worktrees are clean.
for wt in "$WORKTREE_A" "$WORKTREE_B"; do
    if [[ -n "$(git -C "$wt" status --porcelain)" ]]; then
        echo "ab_runner: worktree $wt has uncommitted changes — aborting" >&2
        exit 1
    fi
done

# Capture before-state.
BENCH_GIT_SHA="${SHA_A:0:7}->${SHA_B:0:7}" \
    bash "$REPO_ROOT/scripts/host_state.sh" \
    > "$OUT_DIR/host-state-before.json"

# Build both bench-ci binaries fresh.
echo "ab_runner: building ref_a bench-ci" >&2
( cd "$WORKTREE_A" && zig build bench-ci -Doptimize=ReleaseSafe --help >/dev/null 2>&1 || true )
# We don't actually invoke bench-ci through `zig build` because that would run
# the bench too; instead we drop down to the raw exe so we can override --out.
# But the easiest portable path is to invoke `zig build bench-ci -- --rounds 0
# --warmups 0` once just to compile the artifact; subsequent runs reuse the
# cached binary. Trade-off: small dummy run.
# (Workaround for the lack of a "build only" subcommand.)

build_one() {
    local wt=$1; shift
    local extra_d=("$@")
    ( cd "$wt" && zig build bench-ci -Doptimize=ReleaseSafe "${extra_d[@]}" -- --rounds 1 --warmups 0 --out /tmp/bench-warmup-build/ >/dev/null )
    rm -rf /tmp/bench-warmup-build
}

build_one "$WORKTREE_A"
B_BUILD_FLAGS=()
if [[ -n "$DISABLE_FLAG" ]]; then
    B_BUILD_FLAGS+=("-D${DISABLE_FLAG}=false")
fi
build_one "$WORKTREE_B" "${B_BUILD_FLAGS[@]}"

run_variant() {
    local wt=$1
    local label=$2
    local sha=$3
    local round=$4
    local extra_d=("${@:5}")
    BENCH_GIT_SHA="$sha" \
        env -C "$wt" zig build bench-ci -Doptimize=ReleaseSafe "${extra_d[@]}" -- \
            --rounds 1 --warmups 0 \
            --out "$REPO_ROOT/$OUT_DIR/raw/$label/round-$(printf '%03d' "$round")/" \
        >/dev/null
}

# Warmup rounds (discarded from compare).
echo "ab_runner: warmup ($WARMUPS rounds per variant)" >&2
for ((w = 0; w < WARMUPS; w++)); do
    run_variant "$WORKTREE_A" "warmup_a" "$SHA_A" "$w"
    run_variant "$WORKTREE_B" "warmup_b" "$SHA_B" "$w" "${B_BUILD_FLAGS[@]}"
done

# Alternating measured rounds.
echo "ab_runner: $ROUNDS measured rounds (alternating A/B)" >&2
for ((i = 0; i < ROUNDS; i++)); do
    run_variant "$WORKTREE_A" "ref_a" "$SHA_A" "$i"
    run_variant "$WORKTREE_B" "ref_b" "$SHA_B" "$i" "${B_BUILD_FLAGS[@]}"
done

# Capture after-state.
BENCH_GIT_SHA="${SHA_A:0:7}->${SHA_B:0:7}" \
    bash "$REPO_ROOT/scripts/host_state.sh" \
    > "$OUT_DIR/host-state-after.json"

# Persist exact commands for evidence.
cat > "$OUT_DIR/commands.sh" <<EOF
#!/usr/bin/env bash
# Replay of the A/B run that produced this directory.
# ref_a=$SHA_A
# ref_b=$SHA_B
# disable_flag=${DISABLE_FLAG:-none}
git worktree add --detach $WORKTREE_A $SHA_A
git worktree add --detach $WORKTREE_B $SHA_B
( cd $WORKTREE_A && zig build bench-ci -Doptimize=ReleaseSafe -- --rounds $ROUNDS --warmups $WARMUPS --out raw/ref_a/ )
( cd $WORKTREE_B && zig build bench-ci -Doptimize=ReleaseSafe ${B_BUILD_FLAGS[*]:-} -- --rounds $ROUNDS --warmups $WARMUPS --out raw/ref_b/ )
git worktree remove $WORKTREE_A
git worktree remove $WORKTREE_B
python3 scripts/compare.py --dir $OUT_DIR/raw/ref_b --baseline-dir $OUT_DIR/raw/ref_a --gate
EOF
chmod +x "$OUT_DIR/commands.sh"

# Run aggregation + gate.
python3 "$REPO_ROOT/scripts/compare.py" \
    --dir "$OUT_DIR/raw/ref_b" \
    --baseline-dir "$OUT_DIR/raw/ref_a" \
    --gate \
    > "$OUT_DIR/summary.txt"
COMPARE_EXIT=$?

cat "$OUT_DIR/summary.txt"

# AB metadata.
cat > "$OUT_DIR/ab_run_meta.json" <<EOF
{
  "ref_a": "$SHA_A",
  "ref_b": "$SHA_B",
  "rounds": $ROUNDS,
  "warmups": $WARMUPS,
  "disable_flag": "${DISABLE_FLAG:-none}",
  "out_dir": "$OUT_DIR"
}
EOF

exit "$COMPARE_EXIT"
