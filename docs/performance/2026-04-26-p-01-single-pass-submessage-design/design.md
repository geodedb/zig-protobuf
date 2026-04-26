# P-01 design — single-pass writeSubmessage

**Date:** 2026-04-26
**Branch:** `perf/p-01-single-pass-submessage`
**Status:** Investigation — naive approach failed; correct fix tracked as a follow-up.

## Goal

Replace the per-submessage `std.Io.Writer.Allocating` temp buffer in
`src/protobuf.zig:writeSubmessage` so encode of a nested protobuf
message no longer allocates one bounce buffer per submessage and no
longer memcpy's that buffer into the destination writer.

The architecture document (§ "Targeted hotspots") expects ≥ 20 % gain
on the integration encode scenario from this work.

## Investigated approach (failed)

Use `std.Io.Writer.Discarding` (a stdlib zero-allocation byte-counter
writer) for a measurement pass, then encode directly into the
destination writer with the size known up-front:

```zig
fn writeSubmessage(writer, allocator, value) !void {
    var sink_buf: [4096]u8 = undefined;
    var discarding: std.Io.Writer.Discarding = .init(&sink_buf);
    try encode(&discarding.writer, allocator, value);
    const size = discarding.fullCount();

    try writeRawVarint(writer, size);
    try encode(writer, allocator, value);
}
```

The implementation was correct (140/140 tests pass under both
`-Duse-single-pass-submessage=true` and `false`) and visibly removes
the temp buffer allocation.

### Why it lost catastrophically

A single-shot bench against the encode-fixture-vector-tile-roundtrip
scenario (5 rounds, ReleaseSafe):

| Variant | Median (ns) | allocs/op |
|---------|------------:|----------:|
| naive single-pass | **21,952,687** | 20,985 |
| original 2-pass (heap temp) | 5,146,067 | 14,579 |

The naive version is **~4.3 × slower**, not faster. Cause: every
nested submessage executes the same two-pass discipline. Total work
for a graph with depth `d` is `Σ 2^k` — exponential in nesting depth.
For `vector_tile.bin` (~3-4 levels of nesting per layer ×
many layers), that explains the 4 × multiplier almost exactly.

The implementation also issued *more* allocations (20,985 vs 14,579)
because the second encode pass instantiates fresh
`std.Io.Writer.Allocating` instances inside any nested submessages
that the size-pass already enumerated.

The naive approach is reverted in this commit; the wire path is
unchanged from `main`.

## Why the textbook fix isn't trivial here

Real protobuf encoders use one of:

1. **Size cache.** A single top-down walk records the exact encoded
   size of every value (and recursively, of every submessage) into a
   side table keyed by pointer. The encode pass then reads sizes from
   the table instead of recomputing them.
   - Pro: O(n) work, single walk produces all sizes simultaneously.
   - Con: needs a hashmap keyed by `*const anyopaque`, threaded
     through `encode` / `writeValue` / `writeSubmessage`. The current
     encode signature does not carry that context. Threading it
     through is invasive.

2. **Placeholder + patch-back.** Reserve `max_varint_bytes(payload)`
   bytes for the length prefix, write the body, then go back and
   overwrite the placeholder with the actual length (left-padded with
   continuation bits if the actual length needs fewer bytes than the
   reserved slot).
   - Pro: single forward walk; no extra allocations.
   - Con: requires the destination writer to support random-access
     writes, which `std.Io.Writer` (a streaming abstraction) does
     not generally guarantee. Works for `Writer.fixed` and
     `Writer.Allocating` (since it owns an `ArrayListUnmanaged(u8)`
     internally) but breaks for arbitrary writers like a sockets
     wrapper.
   - Workaround: detect the writer kind and special-case the
     allocating variant — but that couples encode to a specific
     writer type and undermines the abstraction.

3. **Stack-buffered temp on small submessages.** Keep the existing
   2-pass shape, but use a stack-allocated `[N]u8` buffer for the
   first pass instead of `std.Io.Writer.Allocating`. Falls back to
   the heap variant when the stack buffer overflows.
   - Pro: small change; eliminates the alloc for typical-sized
     submessages.
   - Con: only saves the `Allocating.init` + `deinit` pair and the
     small alloc/realloc churn; doesn't eliminate the memcpy. Likely
     a small gain (single-digit %), nowhere near the 20 % target.

## Recommended next step

Approach (1) — size-cache walk — is the only one that is both
correct and abstraction-respecting. It requires:

- A `MeasureContext` struct holding a `std.AutoHashMapUnmanaged(*const anyopaque, u64)`.
- A `pub fn measureMessage(comptime T, value: T, ctx: *MeasureContext) usize` that mirrors `encode` and populates the cache for every submessage encountered.
- An `EncodeContext` carrying the same cache, threaded through `encode`/`writeValue`/`writeSubmessage`.
- `writeSubmessage` becomes: read size from cache → write varint → encode body directly.

That is a multi-day refactor of the encode pipeline. It deserves its
own architecture document and a separate plan.json under
`docs/performance/`. The branch `perf/p-01-single-pass-submessage`
will be left in place pending that work; this design note captures
why the obvious thing didn't work and what to try next.

## What this branch produced

- `build.zig` + `utils/build_util.zig` + `scripts/compare.py`
  cherry-picked from the P-02 branch so any future P-01 work can
  ride the bench harness independently of P-02.
- This design note. Nothing else.

The branch can be discarded or kept alive as a parking spot for the
proper size-cache implementation. If we discard, the
`-Duse-single-pass-submessage` build option introduced in the
infrastructure cherry-pick remains a no-op until a real
implementation reads it.
