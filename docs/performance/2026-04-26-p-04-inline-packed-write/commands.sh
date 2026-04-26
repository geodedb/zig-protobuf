#!/usr/bin/env bash
# Replay of the A/B run that produced this directory.
# ref_a=646ba3f3b0244335496e2ce75b2c9e7f823c2f9f
# ref_b=1f479632002238597d5c4af2b373ae30e3344e9a
# disable_flag=none
git worktree add --detach docs/performance/ab-worktrees/wt-a-646ba3f 646ba3f3b0244335496e2ce75b2c9e7f823c2f9f
git worktree add --detach docs/performance/ab-worktrees/wt-b-1f47963 1f479632002238597d5c4af2b373ae30e3344e9a
( cd docs/performance/ab-worktrees/wt-a-646ba3f && zig build bench-ci -Doptimize=ReleaseSafe -- --rounds 10 --warmups 1 --out raw/ref_a/ )
( cd docs/performance/ab-worktrees/wt-b-1f47963 && zig build bench-ci -Doptimize=ReleaseSafe  -- --rounds 10 --warmups 1 --out raw/ref_b/ )
git worktree remove docs/performance/ab-worktrees/wt-a-646ba3f
git worktree remove docs/performance/ab-worktrees/wt-b-1f47963
python3 scripts/compare.py --dir docs/performance/2026-04-26-p-04-inline-packed-write/raw/ref_b --baseline-dir docs/performance/2026-04-26-p-04-inline-packed-write/raw/ref_a --gate
