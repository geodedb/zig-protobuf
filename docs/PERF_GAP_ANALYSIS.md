# Performance Gap Analysis — devnw/zig/protobuf

**Generated:** 2026-04-26
**Scope:** entire repo
**Library type:** Pure encode/decode library — no I/O loop, no concurrency

## Baseline

- `zig build test` (Debug, includes proto regeneration): 1.42s wall, 3.44s CPU
- ReleaseFast timing: NOT YET CAPTURED — see P-11
- Per-fixture decode/encode throughput: NOT MEASURED — see P-12

## Summary

| PerfSeverity | Count |
|-------------|-------|
| P0 | 3 |
| P1 | 6 |
| P2 | 1 |
| P3 | 6 (incl 3 infra + 3 generator) |
| **Total** | **16** |

**Top finding (PerfScore):** P-01 — writeSubmessage 2-pass alloc-then-write (tied with P-02 — decodeScalar varint byte-at-a-time).

### Top 5 risks with expected impact

1. **P-01** writeSubmessage 2-pass alloc-then-write — ~45% encode-path latency reduction on submessage-heavy schemas; eliminates per-submessage `dupe` allocation.
2. **P-02** decodeScalar varint byte-at-a-time — ~15% reduction in scalar decode latency once a fast-path for ≤2-byte varints lands; varint is the single most-executed wire decode path.
3. **P-03** decodeMessage `inline for` tag dispatch — ~25% reduction in per-field dispatch on wide messages (e.g. 447-field conformance proto), schema-dependent.
4. **P-08** JSON parse field-name dispatch O(N_fields × N_keys) — ~50% JSON parse improvement on wide messages once perfect-hash or sorted-name binary search is in place.
5. **P-06** String/bytes always copied — ~30% throughput improvement on string-heavy decodes via opt-in borrow mode (lifetime tied to input slice).

## PerfScore Formula

`PerfScore = severity_weight × est_improvement_pct × (real_world_likelihood / effort)`

Severity weights: **P0=10, P1=5, P2=2, P3=1.** Likelihood and effort each on a 1–5 scale.

## Findings (sorted by PerfScore desc)

| Rank | ID | PerfSeverity | PerfScore | File:Line | Title | Component | Effort | Likelihood | Est. % |
|------|----|--------------|-----------|-----------|-------|-----------|--------|------------|--------|
| 1 | P-01 | P0 | 750.0 | src/protobuf.zig:261-274 | writeSubmessage 2-pass alloc-then-write | app | 3 | 5 | 45 |
| 2 | P-02 | P0 | 750.0 | src/wire.zig:202-262 | decodeScalar varint byte-at-a-time, no fast path | app | 1 | 5 | 15 |
| 3 | P-03 | P0 | 333.3 | src/wire.zig:543-1048 | decodeMessage O(N_fields) inline-for tag dispatch | app | 3 | 4 | 25 |
| 4 | P-08 | P1 | 250.0 | src/json.zig:39-92 | JSON parse field-name dispatch O(N_fields × N_keys) | app | 2 | 2 | 50 |
| 5 | P-11 | P3 | 250.0 | build.zig | Default `optimize=Debug` for `zig build test`; no `bench` step | infra | 1 | 5 | 50 (gating) |
| 6 | P-07 | P1 | 200.0 | src/protobuf.zig:180-187, 242-257 | writeRawVarint/writeFixed per-byte writeByte | app | 1 | 5 | 8 |
| 7 | P-04 | P1 | 150.0 | src/protobuf.zig:277-386 | 4× writePacked\*List temp buffers | app | 2 | 4 | 15 |
| 8 | P-06 | P1 | 150.0 | src/wire.zig:596-604, 858-866 | String/bytes always copied; no borrow mode | app | 3 | 3 | 30 |
| 9 | P-13 | P3 | 150.0 | (new) bench/ | No allocation-counting allocator wrapper | infra | 1 | 5 | 30 (gating) |
| 10 | P-14 | P3 | 140.0 | bootstrapped-generator/main.zig:179-198 | generator getOutputLines O(F × D × F) | gen | 1 | 2 | 70 |
| 11 | P-12 | P3 | 125.0 | (new) bench/main.zig + tests/fixtures/ | No bench harness; graphics.bin (1.1MB) and vector_tile.bin (125KB) unused | infra | 2 | 5 | 50 (gating) |
| 12 | P-05 | P1 | 120.0 | src/wire.zig:393-457 | decodeRepeated no `ensureTotalCapacity` | app | 1 | 3 | 8 |
| 13 | P-09 | P1 | 100.0 | src/json.zig:117-123 | json.encode uses valueAlloc returning owned slice | app | 1 | 2 | 10 |
| 14 | P-10 | P2 | 20.0 | src/protobuf.zig:702-731 | dupeField append vs appendAssumeCapacity | app | 1 | 2 | 5 |
| 15 | P-15 | P3 | 20.0 | bootstrapped-generator/main.zig:909-942 | isMessageSelfReferential allocates fresh StringHashMap per call | gen | 1 | 2 | 10 |
| 16 | P-16 | P3 | 20.0 | bootstrapped-generator/main.zig:152 | std.mem.concat + per-line allocPrint in generator | gen | 2 | 2 | 20 |

---

## Detailed Findings

### P-01 — writeSubmessage 2-pass alloc-then-write [P0, PerfScore 750.0]

**File:** `src/protobuf.zig:261-274`
**Diagnosis:** Encoding a submessage currently builds the inner payload into a separately-allocated `ArrayList`, length-prefixes it, then copies into the parent writer. Every nested submessage triggers an allocator round-trip and a redundant memcpy. On submessage-heavy schemas (vector_tile, descriptors), this dominates encode CPU.
**Cheap fix sketch:** Reserve a 5-byte placeholder for the LEN varint in the parent writer, encode the submessage in place, then back-patch the length (memmove only on overflow into >5-byte varint, which is unreachable for any payload <2GB). One allocator call per top-level encode.

### P-02 — decodeScalar varint byte-at-a-time, no fast path [P0, PerfScore 750.0]

**File:** `src/wire.zig:202-262`
**Diagnosis:** Varint decode loops one byte at a time with a high-bit check on every iteration. The vast majority of real protobuf varints are 1–2 bytes (small tag numbers, small ints, booleans). Every scalar decode pays branch + shift + mask cost N times.
**Cheap fix sketch:** Add a 1-byte fast path (`if input[0] < 0x80 return input[0]`) and an inlined 2-byte fast path before the generic loop. ~15% throughput uplift on real wire data; zero correctness risk (purely a layered specialization).

### P-03 — decodeMessage O(N_fields) inline-for tag dispatch [P0, PerfScore 333.3]

**File:** `src/wire.zig:543-1048`
**Diagnosis:** Per-tag dispatch is generated as an `inline for` over every declared field, which lowers to a linear chain of comparisons. On wide schemas (e.g. the 447-field `conformance.proto`), every wire-tag decode walks an O(N) chain. Cache and branch-predictor unfriendly.
**Cheap fix sketch:** Generate a `switch` over the tag value with one prong per declared field. Zig 0.16 lowers dense switches to a jump table or binary search; either is asymptotically better than the inline-for chain. Verify Zig 0.16 switch-prong feasibility for sparse tag numbers (a binary-search prong layout still beats linear).

### P-04 — 4× writePacked\*List temp buffers [P1, PerfScore 150.0]

**File:** `src/protobuf.zig:277-386`
**Diagnosis:** Four near-identical `writePackedVarintList` / `writePackedFixed*List` functions each allocate a temp `ArrayList`, fill it, length-prefix, then copy. Identical pattern to P-01 at the packed-list level.
**Cheap fix sketch:** Length-prefix back-patching on the parent writer (same pattern as the P-01 fix). Optionally collapse the four functions into a single generic over wire kind to reduce maintenance.

### P-05 — decodeRepeated no ensureTotalCapacity [P1, PerfScore 120.0]

**File:** `src/wire.zig:393-457`
**Diagnosis:** Repeated-field decode appends one element at a time without a pre-sized capacity. For packed repeated, the inner byte length is known before the loop; for non-packed, a one-time over-estimate (bytes_remaining / min_element_size) avoids the doubling-realloc churn.
**Cheap fix sketch:** For packed: divide `inner_len` by element wire size, call `ensureTotalCapacity`. For non-packed: bound by remaining byte count.

### P-06 — String/bytes always copied; no borrow mode [P1, PerfScore 150.0]

**File:** `src/wire.zig:596-604, 858-866`
**Diagnosis:** `string` and `bytes` fields are always `dupe`'d on decode. For zero-copy parsing scenarios (read-only access, lifetime tied to input buffer), this doubles memory and adds a memcpy per field.
**Cheap fix sketch:** Add a `decodeBorrow` variant or a `DecodeOptions{ .borrow_strings = true }` parameter. When borrowing, the decoded message lifetime is bound to the input slice — document clearly. Opt-in only; default keeps current ownership semantics.

### P-07 — writeRawVarint/writeFixed per-byte writeByte [P1, PerfScore 200.0]

**File:** `src/protobuf.zig:180-187, 242-257`
**Diagnosis:** Both helpers loop calling `writer.writeByte`. Each `writeByte` is a `Writer` virtual call (or at minimum a bounds check + append). Five round-trips for a 5-byte varint.
**Cheap fix sketch:** Build into a stack `[10]u8` buffer, call `writer.writeAll` once. Same for fixed32/fixed64 (`@bitCast` to `[4]u8`/`[8]u8`, single `writeAll`).

### P-08 — JSON parse field-name dispatch O(N_fields × N_keys) [P1, PerfScore 250.0]

**File:** `src/json.zig:39-92`
**Diagnosis:** For every JSON object key, the parser walks every field of the target struct via `inline for` and compares the key string. With N keys and F fields the parser is O(N·F). At 447 fields this is brutal.
**Cheap fix sketch:** comptime-build a sorted name array per type and binary-search at runtime, or generate a comptime-hashed dispatch (perfect hash via small switch on string length + first/last char). Keep `inline for` only as the fallback for cases the comptime hash can't disambiguate.

### P-09 — json.encode uses valueAlloc returning owned slice [P1, PerfScore 100.0]

**File:** `src/json.zig:117-123`
**Diagnosis:** Encoder builds the JSON value tree via `valueAlloc` and only then serializes, doubling memory traffic. `std.json.Stringify` supports streaming directly into a `Writer`.
**Cheap fix sketch:** Replace `valueAlloc` round-trip with a streaming `Stringify` writer that walks the message struct directly. Drops the temp tree entirely.

### P-10 — dupeField append vs appendAssumeCapacity [P2, PerfScore 20.0]

**File:** `src/protobuf.zig:702-731`
**Diagnosis:** `dupeField` for repeated/string fields uses plain `append` which checks capacity each iteration. Length is known upfront in every callsite.
**Cheap fix sketch:** `ensureTotalCapacityPrecise(len)` then `appendAssumeCapacity` in the loop. Trivial.

### P-11 — Default `optimize=Debug` for `zig build test`; no `bench` step [P3, PerfScore 250.0]

**File:** `build.zig`
**Diagnosis:** `zig build test` runs Debug, which both inflates baseline timings and is unsuited for any perf measurement. There is no `zig build bench` step; nothing forces ReleaseFast for perf runs. **Gates every other validation step.**
**Cheap fix sketch:** Add a `bench` step bound to ReleaseFast, depending on a new `bench/main.zig` (see P-12). Keep `test` Debug for correctness; add `test-release` for the rare perf-sensitive correctness check.

### P-12 — No bench harness; tests/fixtures unused for perf [P3, PerfScore 125.0]

**File:** `tests/fixtures/graphics.bin` (1.1MB), `tests/fixtures/vector_tile.bin` (125KB), `(new) bench/main.zig`
**Diagnosis:** Two real-world fixtures already live in the repo and are read by the test suite for correctness only. There is no harness to measure decode/encode throughput against them. **Gates measurement of every app-layer finding.**
**Cheap fix sketch:** 30-line `bench/main.zig` (skeleton in next section) that loads each fixture, runs N=10000 iterations of decode + encode, prints ns/op and bytes/op. Wire it to `zig build bench`.

### P-13 — No allocation-counting allocator wrapper [P3, PerfScore 150.0]

**File:** `(new) bench/alloc_counter.zig`
**Diagnosis:** Many of the P0/P1 fixes (P-01, P-04, P-05, P-10) reduce *allocation counts*, not just nanoseconds. Without an alloc-counting allocator wrapper, validation has no way to confirm the alloc reduction landed.
**Cheap fix sketch:** Tiny `Allocator` wrapper that increments counters on `alloc/resize/free` and exposes `count` / `bytes`. Plug into bench harness so each row reports both timing and alloc count.

### P-14 — generator getOutputLines O(F × D × F) [P3, PerfScore 140.0]

**File:** `bootstrapped-generator/main.zig:179-198`
**Diagnosis:** For each field, the generator re-scans every dependency, and within each dependency re-scans every field — O(F × D × F) per message. Build-time only, but cumulative across large schemas.
**Cheap fix sketch:** Cache the dependency lookup per message in a `StringHashMap`. One pass instead of cubic.

### P-15 — isMessageSelfReferential allocates fresh StringHashMap per call [P3, PerfScore 20.0]

**File:** `bootstrapped-generator/main.zig:909-942`
**Diagnosis:** Each invocation allocates a `StringHashMap`, populates, then frees. Build-time only; minor.
**Cheap fix sketch:** Hoist the visited-set into a caller-provided scratch map; reuse across calls. Or pass an `Allocator.scratch` arena that resets per top-level message.

### P-16 — std.mem.concat + per-line allocPrint in generator [P3, PerfScore 20.0]

**File:** `bootstrapped-generator/main.zig:152`
**Diagnosis:** Generator emits source by `allocPrint`-ing each line then `std.mem.concat`-ing the slices. Many small allocs and a final big concat. Build-time only.
**Cheap fix sketch:** Build into a single `ArrayList(u8)` writer with `print` calls; no intermediate slice allocation.

---

## Bench Harness Recommendation (gates P-01..P-10 validation)

Skeleton — drop into `bench/main.zig` and add a `bench` step in `build.zig`.

```zig
// bench/main.zig
const std = @import("std");
const protobuf = @import("protobuf");
// const VectorTile = @import("...vector_tile.pb.zig").Tile;

const ITERS: usize = 10_000;

fn nsPerIter(start: i128, end: i128) u64 {
    return @intCast(@divTrunc(end - start, ITERS));
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const fixtures = .{
        .{ .name = "vector_tile.bin", .path = "tests/fixtures/vector_tile.bin" },
        .{ .name = "graphics.bin",    .path = "tests/fixtures/graphics.bin" },
    };

    inline for (fixtures) |f| {
        const bytes = try std.fs.cwd().readFileAlloc(alloc, f.path, 16 * 1024 * 1024);
        defer alloc.free(bytes);

        // Decode loop
        var t0 = std.time.nanoTimestamp();
        var i: usize = 0;
        while (i < ITERS) : (i += 1) {
            // var msg = try Tile.decode(bytes, alloc);
            // defer msg.deinit();
            std.mem.doNotOptimizeAway(bytes);
        }
        var t1 = std.time.nanoTimestamp();
        std.debug.print("{s} decode: {d} ns/op\n", .{ f.name, nsPerIter(t0, t1) });

        // Encode loop (re-use a decoded message)
        // ...
    }
}
```

```zig
// build.zig (additive)
const bench = b.step("bench", "Run perf benchmarks (ReleaseFast)");
const bench_exe = b.addExecutable(.{
    .name = "bench",
    .root_source_file = b.path("bench/main.zig"),
    .target = target,
    .optimize = .ReleaseFast,
});
bench_exe.root_module.addImport("protobuf", protobuf_module);
const run_bench = b.addRunArtifact(bench_exe);
bench.dependOn(&run_bench.step);
```

Pair with P-13 alloc counter to report both ns/op and allocs/op per fixture.

---

## Effort/Impact Ranked List (Quick Wins → Strategic)

### Quick wins (< 1 day, effort=1)

- **P-02** varint fast path — single function, ~15% decode uplift, no API change.
- **P-07** writeRawVarint/writeFixed buffered writeAll — single function each, ~8% encode uplift.
- **P-05** `ensureTotalCapacity` in decodeRepeated — one-line fix per call site.
- **P-10** appendAssumeCapacity in dupeField — one-line fix.
- **P-11** Add `bench` step in build.zig — gates everything else.
- **P-13** Alloc-counter allocator wrapper — gates alloc-count validation.
- **P-14, P-15** Generator caching fixes — build-time only, low risk.

### Medium (1–5 days, effort=2–3)

- **P-01** writeSubmessage back-patching — biggest single encode win, but touches the encode core; needs careful test coverage on edge cases (empty submessages, very large submessages).
- **P-03** decodeMessage switch dispatch — comptime-generated switch; verify Zig 0.16 switch-prong handling for sparse field numbers.
- **P-04** Packed list back-patching — same pattern as P-01, applies once P-01 is in.
- **P-06** Borrow mode for strings/bytes — opt-in; needs lifetime documentation and a `DecodeOptions` param thread.
- **P-08** JSON perfect-hash field dispatch — comptime work, but localized to `json.zig`.
- **P-09** Streaming JSON encode — replace `valueAlloc` round-trip with `Stringify` writer.
- **P-12** Bench harness with fixtures — small but blocked on P-11.
- **P-16** Generator single-buffer emit — refactor of generator core writer.

### Strategic (> 5 days)

- None at present. All identified findings are scoped to single-file or single-module changes. A future SIMD varint vectorization (e.g. parsing 8 varints in parallel via PEXT/AVX2) would land here, but is out of scope for this audit.

---

## Sequencing Recommendation

1. **Land P-11 + P-13 + P-12 first** — no measurement = no validation. None of the app-layer fixes can be defended without these.
2. **P-02** (smallest, immediate win, validates the new harness end-to-end with a real ns/op delta).
3. **P-01** (largest single encode win; biggest payoff per engineering hour once P-12 fixtures can validate it).
4. **P-03** (largest schema-dependent win; verify Zig 0.16 switch-prong feasibility on sparse field numbers before committing).
5. **P-04, P-07, P-05, P-10** as a single batch — all small, all touch encode/decode hot paths, share validation runs.
6. **P-08** if JSON is on the hot path for any consumer — otherwise defer.
7. **P-06 + P-09 + generator items (P-14, P-15, P-16)** — opt-in / build-time, lowest urgency, land as capacity allows.

---

## Unknowns / Blockers / Suspected Items

- **ReleaseFast baseline:** Not yet captured. Blocked on P-11. Without it, every "X% improvement" claim above is a Debug-build estimate and may shrink (compiler already inlines a lot) or grow (loops that Debug can't unroll) under ReleaseFast.
- **P-03 lowering:** Whether Zig 0.16 generates a jump table vs binary search for the proposed switch on sparse field numbers needs `-femit-asm` inspection on the conformance proto. Suspected confirmed pattern; needs disassembly to confirm magnitude.
- **P-06 borrow-mode demand:** No external user reports requesting it. Sized at 30% improvement assuming a string-heavy workload that opts in; for the average schema the win may be smaller. Confirm by surveying current consumers (vector_tile is string-heavy → likely real win).
- **P-08 JSON hot-path-ness:** The wire format is the documented primary path. JSON support exists but its real-world hot-path frequency is unknown. Confirm before sinking effort here.
- **Generator items (P-14, P-15, P-16):** Build-time only. Wins are real but only matter for users with very large `.proto` schemas; for the conformance proto regeneration, expected wall-clock impact is sub-second.

---

## Closure Status (last updated 2026-04-26 after perf sprint #1)

| ID | Status | Closed by | Notes |
|----|--------|-----------|-------|
| P-01 | **Deferred** | MR !2 (`ce4a045`) | Naive single-pass is `O(2^depth)`, 4.3× slower. Design note for size-cache walk at `docs/performance/2026-04-26-p-01-single-pass-submessage-design/design.md`. `-Duse-single-pass-submessage` flag wired as no-op. |
| P-02 | **Closed** | MR !1 (`dc243e9`) | Fast-path varint decode. -7.14 % on `decode-varint-10byte-i64`, 20×/20× stress clean. Toggle: `-Duse-fast-varint=false`. |
| P-03 | **Deferred** | RESOLVED entry only | 559-line dispatch already lowers to LLVM jump tables under `inline for`; no small-message bench fixture to validate the architecture's ≥10 % estimate. `-Duse-fast-tag-dispatch` flag wired as no-op. |
| P-04 | **Closed** | MR !4 (`e4c20a5`) | Inline packed-list writers, no temp buffer. -10.05 % on `dupe-fixture-vector-tile` via -27 % allocs/op on encode. Toggle: `-Duse-inline-packed-write=false`. |
| P-05 | **Closed** | MR !3 (`646ba3f`) | `ensureTotalCapacity` in packed decode loops. -6.15 % on `decode-fixture-graphics-deep`. Toggle: `-Duse-ensure-capacity-packed=false`. |
| P-06 | **Open** | — | Borrow mode for strings/bytes. Out of scope for perf sprint #1 (needs `DecodeOptions` thread + lifetime documentation). |
| P-07 | **Closed** (prior run) | `40ffe07` | Stack-buffered `writeRawVarint`/`writeFixed`. |
| P-08 | **Deferred** | MR !5 (`30f008b`) | Length-bucketed JSON dispatch attempted, neutral on `vector_tile` (per-struct field counts ≤7), reverted. Design note at `docs/performance/2026-04-26-p-08-fast-json-key-dispatch/decision.md`. `-Duse-fast-json-key-dispatch` flag wired as no-op. Re-attempt when a wider-schema JSON fixture lands or with a comptime size gate (`if (fields.len >= 16)`). |
| P-09 | **Closed** | `c9bd4c1` | `pub fn encodeToWriter` exposed. Audit premise (value-tree round-trip) was stale; Zig 0.16.0's `std.json.Stringify` already streams. API addition for writer-owning consumers. |
| P-10 | **Closed** (prior run) | `40ffe07` | `appendAssumeCapacity` in `dupeField`. |
| P-11 | **Closed** (prior run) | `913e626` | `bench` step in `build.zig`. |
| P-12 | **Closed** (prior run) | `913e626` | Bench harness with fixtures. Replaced with the 3-layer harness in MR !1. |
| P-13 | **Closed** (prior run + perf sprint #1) | `913e626` + `09fa0d8` | Allocation-counting allocator wrapper. Now `bench/framework.CountingAllocator`. |
| P-14 | **Open** | — | Generator `getOutputLines` O(F × D × F). Build-time only, low priority. |
| P-15 | **Open** | — | Generator `isMessageSelfReferential` allocates fresh StringHashMap per call. Build-time only. |
| P-16 | **Open** | — | Generator `std.mem.concat` + per-line `allocPrint`. Build-time only. |

Total: 7 closed (P-02, P-04, P-05, P-07, P-09, P-10, P-11+P-12+P-13 infra), 3 deferred with handoff (P-01, P-03, P-08), 4 open generator/feature items (P-06, P-14, P-15, P-16). Detailed closure entries with measured deltas live in `GAP_ANALYSIS_RESOLVED.md` under "perf sprint #1".

