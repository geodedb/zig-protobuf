#!/usr/bin/env bash
# Replay of the A/B run that produced this directory.
# ref_a=e4c20a5792f5e2bf5298ca4882f764da314d73bb
# ref_b=2b474019209e6f608c17177178d2f24f7599fd59
# disable_flag=none
git worktree add --detach docs/performance/ab-worktrees/wt-a-e4c20a5 e4c20a5792f5e2bf5298ca4882f764da314d73bb
git worktree add --detach docs/performance/ab-worktrees/wt-b-2b47401 2b474019209e6f608c17177178d2f24f7599fd59
( cd docs/performance/ab-worktrees/wt-a-e4c20a5 && zig build bench-ci -Doptimize=ReleaseSafe -- --rounds 10 --warmups 1 --out raw/ref_a/ )
( cd docs/performance/ab-worktrees/wt-b-2b47401 && zig build bench-ci -Doptimize=ReleaseSafe  -- --rounds 10 --warmups 1 --out raw/ref_b/ )
git worktree remove docs/performance/ab-worktrees/wt-a-e4c20a5
git worktree remove docs/performance/ab-worktrees/wt-b-2b47401
python3 scripts/compare.py --dir docs/performance/2026-04-26-p-08-fast-json-key-dispatch/raw/ref_b --baseline-dir docs/performance/2026-04-26-p-08-fast-json-key-dispatch/raw/ref_a --gate
