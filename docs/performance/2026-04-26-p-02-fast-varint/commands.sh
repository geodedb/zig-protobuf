#!/usr/bin/env bash
# Replay of the A/B run that produced this directory.
# ref_a=09fa0d867f6bf592ea9aed94e9443d2ac601d9c9
# ref_b=fe7fee1d25f8c123ae1494282708a786e6e1b513
# disable_flag=none
git worktree add --detach docs/performance/ab-worktrees/wt-a-09fa0d8 09fa0d867f6bf592ea9aed94e9443d2ac601d9c9
git worktree add --detach docs/performance/ab-worktrees/wt-b-fe7fee1 fe7fee1d25f8c123ae1494282708a786e6e1b513
( cd docs/performance/ab-worktrees/wt-a-09fa0d8 && zig build bench-ci -Doptimize=ReleaseSafe -- --rounds 10 --warmups 1 --out raw/ref_a/ )
( cd docs/performance/ab-worktrees/wt-b-fe7fee1 && zig build bench-ci -Doptimize=ReleaseSafe  -- --rounds 10 --warmups 1 --out raw/ref_b/ )
git worktree remove docs/performance/ab-worktrees/wt-a-09fa0d8
git worktree remove docs/performance/ab-worktrees/wt-b-fe7fee1
python3 scripts/compare.py --dir docs/performance/2026-04-26-p-02-fast-varint/raw/ref_b --baseline-dir docs/performance/2026-04-26-p-02-fast-varint/raw/ref_a --gate
