# Decision — P-08 fast JSON key dispatch

**Verdict:** REJECT — optimization shipped behind a flag, A/B'd, found neutral-trending-slightly-slower on this fixture, and reverted.
**Date:** 2026-04-26
**`ref_a`:** `e4c20a5` (main, post-P-04 merge)
**`ref_b`:** `2b47401` (the discarded fast-path attempt on `perf/p-08-fast-json-key-dispatch`)
**Summary line:** `NATIVE_BENCH result=PASS scenarios=18 regressions=0 improvements=0 ref_a=e4c20a57 ref_b=2b474019`

## What was tried

Replaced the per-input-key linear scan in `json.parse` with a
comptime length-bucketed dispatch:

```zig
fn matchFieldIndex(comptime Self, field_name) ?usize {
    // Comptime: group fields' snake_case + camelCase forms by length.
    // Runtime: switch (field_name.len) -> only memcmp candidates of
    //          that exact length.
}
```

Also gated behind `-Duse-fast-json-key-dispatch=false` so the
original linear-scan path stayed available verbatim.

## Why it didn't help (and slightly hurt)

| JSON scenario | baseline (ns) | candidate (ns) | Δ | Status |
|---|--:|--:|--:|---|
| json-decode-fixture-vector-tile | 6,528,618 | 6,707,192 | +2.74% | neutral (within gate) |
| json-encode-fixture-vector-tile | 4,893,832 | 4,925,303 | +0.64% | neutral |

vector_tile JSON's hottest paths dispatch on small structs:

| Type | Field count |
|------|-------------|
| `Tile.Layer.Feature` | 4 |
| `Tile.Layer.Value` | 7 (all `*_value`) |
| `Tile.Layer` | 6 |
| `Tile` | 1 |

For ≤ 7 fields the original `inline for` already compiles to a
small chain of comptime-folded memcmps that LLVM can branch-predict
and length-pre-filter on its own. The length-bucket dispatch adds:

- a runtime `switch (field_name.len)` over a sparse enum of lengths,
- a per-length inline-for over a comptime-built bucket array,
- one extra layer of indirection per key.

Net per-key overhead exceeds saved comparisons until you get to
~30+ fields per struct, which the vector_tile schema doesn't have.

## What this proves

- The bench harness + variance gate correctly classified the
  attempt as **neutral, slightly slower trend** rather than letting
  it ship as a "no-op tested-equivalent improvement". Without the
  gate this would have been a silent regression on the JSON paths.
- The architecture's "≥25 % gain" estimate for P-08 was based on
  schemas wider than vector_tile. To validate it properly, we'd
  need a fixture with one of:
  - A `GraphicsDB` snapshot serialized as JSON (the GraphicsDB
    schema has 30+ fields per type — exactly the case where
    length-bucketing should dominate).
  - A synthetic JSON with hundreds of keys per object.

## Decision

**Revert and document.** The reverted commit (`309d73d`) leaves
`src/json.zig` byte-identical to `main`. The
`use_fast_json_key_dispatch` build option survives in `build.zig`
as a no-op flag — wired and ready to toggle the day a real
implementation lands.

## Recommended next step

Either:

1. Skip P-08 until a representative wide-schema JSON fixture is
   added to `tests/fixtures/`, then retry.
2. Implement length-bucketing only for structs above a comptime
   threshold (e.g., `if (fields.len >= 16) use bucket dispatch
   else fall through to inline-for`) so the optimization is
   gated by struct size at compile time.

Option 2 is cleaner and would land cleanly the day someone
introduces a wide-schema fixture. Tracked as a follow-up.
