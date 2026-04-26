#!/usr/bin/env bash
# Replay of the A/B run that produced this directory.
# ref_a=ce4a04584b88acc78fbd5c53b54cef61dc1b434e
# ref_b=2c59dab42bc99727eee47095dd9170f0cb691366
# disable_flag=none
git worktree add --detach docs/performance/ab-worktrees/wt-a-ce4a045 ce4a04584b88acc78fbd5c53b54cef61dc1b434e
git worktree add --detach docs/performance/ab-worktrees/wt-b-2c59dab 2c59dab42bc99727eee47095dd9170f0cb691366
( cd docs/performance/ab-worktrees/wt-a-ce4a045 && zig build bench-ci -Doptimize=ReleaseSafe -- --rounds 10 --warmups 1 --out raw/ref_a/ )
( cd docs/performance/ab-worktrees/wt-b-2c59dab && zig build bench-ci -Doptimize=ReleaseSafe  -- --rounds 10 --warmups 1 --out raw/ref_b/ )
git worktree remove docs/performance/ab-worktrees/wt-a-ce4a045
git worktree remove docs/performance/ab-worktrees/wt-b-2c59dab
python3 scripts/compare.py --dir docs/performance/2026-04-26-p-05-ensure-capacity-packed/raw/ref_b --baseline-dir docs/performance/2026-04-26-p-05-ensure-capacity-packed/raw/ref_a --gate
