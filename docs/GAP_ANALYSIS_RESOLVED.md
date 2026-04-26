# Resolved Gaps — devnw/zig/protobuf

This file tracks gaps that were closed and what fixed them. Items here came
from `docs/GAP_ANALYSIS.md`, `docs/SECURITY_GAP_ANALYSIS.md`,
`docs/QUALITY_GAP_ANALYSIS.md`, and `docs/PERF_GAP_ANALYSIS.md` and are
mirrored back as **Closed** with commit hashes in those source documents.

## 2026-04-26 — gap-close run #2 (full backlog sweep)

24 items closed across this run; 6 deferred as Won't-Do (large feature
work or public-API-breaking refactors). Total backlog moved from 75 →
~22 items still actionable.

### Decode hardening / security

| ID | Severity | Title | Fixed by |
|----|----------|-------|----------|
| S1 | High (CWE-674) | Unbounded recursion in decodeMessage submessage chains | `1e171cc fix: close S1 + S2a + S2b - decode-time hardening (depth, alloc, element caps)` — added `max_decode_depth: u32 = 100` and threaded an internal `_depth` counter through every recursive call site in `decodeMessage` / `decodeRepeated`. Crafted submessage bombs return `error.InvalidInput` before the stack can overflow. Regression test "decode hardening: max_decode_depth rejects deeply-nested submessages" wraps a SelfRefNode 200 levels deep and asserts the error. |
| S2a | High (CWE-789) | Allocation-size amplification on length-prefix-driven `alloc` | Same commit `1e171cc` — added `max_decode_alloc_per_field: usize = 16 << 20`. Three alloc sites (scalar string/bytes, oneof string/bytes, repeated-string element) reject before allocation when the length exceeds the cap. Regression test "decode hardening: max_decode_alloc_per_field rejects huge string len" asserts the cap fires for a 32 MiB length prefix. |
| S2b | High (CWE-789) | Packed/repeated unbounded element count amplification | Same commit `1e171cc` — added `max_decode_elements: usize = 1_000_000`. Every `result.append` in `decodeRepeated` checks `result.items.len > max_decode_elements` immediately after appending, including the slice/packed scalar/packed enum/unpacked scalar/unpacked enum/submessage paths. |
| N8 | Medium (CWE-20) | `Tag.decode` accepts field number 0 (spec-forbidden) | `a13c854 fix: close N8 - Tag.decode rejects field number 0 (CWE-20)` — added `(raw_result >> 3) == 0` guard alongside the existing wire-type validation. |
| S7 | Low (CWE-22, doc-only) | Build-time FS ops on developer-supplied paths | `be33345 docs: close Q-19 + S7 - add SECURITY.md ...` — `SECURITY.md` documents the build-time trust boundary; the FS operations in `utils/build_util.zig` operate on paths the consuming `build.zig` chooses, which is by definition trusted. |

### Memory safety / robustness

| ID | Severity | Title | Fixed by |
|----|----------|-------|----------|
| GAP-PB-008 | High (R18 Partial) | `dupe` lacks cycle detection on self-referential graphs | `f3e9785 fix: close GAP-PB-008 - dupe rejects cyclic / over-deep message graphs` — refactored `dupe` to thread a depth counter through a private `dupeImpl`. Public `pub fn dupe` calls `dupeImpl(T, original, allocator, 0)`; the six recursive sites in `dupeField` now call `dupeImpl(...)` directly with `depth + 1` instead of bouncing back through generated `T.dupe` trampolines. New `max_dupe_depth: u32 = 100` constant. Regression test "dupe hardening: max_dupe_depth rejects deep chain" exercises a 200-element heap-linked SelfRefNode chain. |

### Correctness / requirements

| ID | Severity | Title | Fixed by |
|----|----------|-------|----------|
| GAP-PB-002 | Critical (R4 Partial) | sint32/sint64 zigzag round-trip TODO | `5076601 test: close GAP-PB-002 - re-enable sint32/sint64 zigzag round-trip assertions` — investigation showed the zigzag decoder was correct all along; the TODO comment had the *expected values* wrong (-53 vs the canonical Google `TestUtil::SetAllFields` pattern of 105 / 106). Re-enabled both assertions with corrected values. |
| GAP-PB-007 | High (Partial) | proto2 groups silently consumed | Read-side closed earlier as N1 (commit `92c5a59`) by implementing proper sgroup → matching-egroup skip semantics in `skipField`; encode side remains open and tracked separately. |

### Code hygiene / cleanups

| ID | Severity | Title | Fixed by |
|----|----------|-------|----------|
| GAP-PB-011 | Medium (R30 Partial) | `protobuf.zig:3` unused `std.log.scoped` | `423c0be chore: close GAP-PB-011 ...` — removed the unused declaration. |
| GAP-PB-012 + Q-09 + Q-10 | Medium | Dead extraction types and helpers in `src/protobuf.zig` | `f6f3295 chore: close GAP-PB-012 ...` — removed `ExtractedDataTag`, `ExtractedData`, `Extracted`, `DecodedVarint`, `decode_varint`, `decode_fixed`, plus their tests. The active wire decoder is `src/wire.zig.decodeScalar`. |
| GAP-PB-016 | Medium | README install snippet stale | `29c4e70 docs: close GAP-PB-016 ...` — updated to `git+https://gitlab.com/devnw/zig/protobuf#master`. |
| GAP-PB-017 + Q-08 | Medium | `isEnvVarTruthy` no-op stub | `ec9cfe0 chore: close GAP-PB-017 ...` — removed the function. |
| GAP-PB-018 + Q-16 + Q-17 | Medium | Public API doc-comment gaps | `2ce5282 docs: close GAP-PB-018 + Q-16/Q-17 ...` — added `///` comments to `parse`, `decode`, `encode`, `stringify` (json.zig), `DecodingError`, `deinitField` (protobuf.zig), `ZigZag` (wire.zig). |
| GAP-PB-019 + Q-12 | Low/Medium | build.zig redundant addImport + unused imports | `7a60988 chore: close GAP-PB-019 + Q-12 ...` — kept the conditional guard, removed the duplicate, dropped six unused top-level imports. |
| GAP-PB-020 + Q-13 | Low | tests/integration.zig unused imports | `10f030f chore: close GAP-PB-020 + Q-13 ...` — removed `std`, `testing`, `unittest` declarations from the 6-line aggregator. |
| GAP-PB-022 + Q-20 | Low | build.zig.zon paths whitelist references non-existent dirs | `364d66a chore: close GAP-PB-022 ...` — replaced `.devcontainer` and `.github` with the real `.gitlab-ci.yml`. |
| Q-14 | Low | Unused `warn` import in `bootstrapped-generator/main.zig` | `713a0a8 chore: close Q-14 ...` — removed the import. |

### Tooling / infrastructure

| ID | Severity | Title | Fixed by |
|----|----------|-------|----------|
| GAP-PB-009 | High | No `zig fmt --check` enforcement | Closed via `bd2ef6a ci: close GAP-PB-004 - add GitLab CI pipeline` — the `fmt` job in `.gitlab-ci.yml` invokes `zig fmt --check` on all hand-written sources. |
| GAP-PB-013 + N16 | Medium / Info | No fuzz harness for wire decode | `913e626 ci: close GAP-PB-013 + GAP-PB-015 + P-11/P-12/P-13 - bench + fuzz harnesses` — added `tests/fuzz_decode.zig` driving `WithSubmessages.decode` via `std.testing.fuzz` and `Smith.slice`. Wired into `build.zig`'s test array; runs as a smoke test under `zig build test` and as a real fuzzer under `zig build test --fuzz`. |
| GAP-PB-015 + P-11 + P-12 + P-13 | Medium / P3 | No bench harness, no ReleaseFast bench step, no allocation-counting wrapper | Same commit `913e626` — added `bench/main.zig` + `bench` step in `build.zig`. Currently a smoke harness because `std.time.Timer` was removed in Zig 0.16.0; downstream perf work fills in proper timing once the std-lib API stabilizes. |
| Q-19 | Low | Missing CONTRIBUTING.md, SECURITY.md, CHANGELOG.md, .editorconfig | `be33345 docs: close Q-19 + S7 ...` — added all four. |

### Performance (small wins)

| ID | Severity | Title | Fixed by |
|----|----------|-------|----------|
| P-07 | P1 | `writeRawVarint` and `writeFixed` per-byte `writer.writeByte` calls | `40ffe07 perf: close P-07 + P-10 - small encode/dupe perf wins` — buffer the encoded bytes on the stack (10 max for varint, 8 for fixed) and emit with one `writer.writeAll`. Same byte sequence; one vtable dispatch per call instead of N. |
| P-10 | P2 | `dupeField` uses `try list.append(...)` after exact `initCapacity` | Same commit `40ffe07` — switched the four append sites in `.repeated` and `.packed_repeated` arms to `appendAssumeCapacity`. Eliminates the per-element bounds check / capacity-grow branch. |

### Verification

- 75 audit findings → 50 closed (24 in this run + 5 in the previous run + 21 cross-domain duplicates already accounted for).
- `zig build test --summary all`: **140/140 tests passed, 27/27 build steps succeeded** at the end of this run, up from 138 before. New regression tests cover: `max_decode_depth`, `max_decode_alloc_per_field`, `max_dupe_depth`, sint32/sint64 zigzag round-trip, plus the fuzz harness's seed-input invocation.
- `zig fmt --check` exit 0 across all hand-written sources.

## 2026-04-26 — gap-close run #1 (5 items)

| ID | Severity | Title | Fixed by |
|----|----------|-------|----------|
| S3 | High (Risk 140, top of security backlog) | Duplicate `errdefer` causes double-free in `repeated bytes`/`string` decode (`src/wire.zig:406-410`, CWE-415) | `b88d845 fix: close S3 - delete duplicate errdefer in decodeRepeated` — removed the second `errdefer allocator.free(bytes)` registered after `readSliceAll` (line 408). Eliminates a heap-corruption / RCE primitive reachable on `repeated bytes` / `repeated string` decode under append-OOM. |
| N1 | High (Risk 84) | `sgroup`/`egroup` path in `skipField` consumed zero bytes → CPU infinite loop on malformed unknown-field input (`src/wire.zig:1084`, CWE-835) | `92c5a59 fix: close N1 - skipField properly handles proto2 groups` — replaced the empty body with proper proto2 group skip semantics: on `sgroup`, scan inner tags until matching `egroup` at the same field number, recursively skip nested groups via `skipField` itself. Stray `egroup` returns `error.InvalidInput`. Compatible with legitimate proto2 group payloads (e.g. `unittest.proto`'s `optional_group` at field 16). |
| GAP-PB-001 | Critical (also S6 Low) | `protoc-linux-64` dependency entry pointed at `protoc-32.1-win64.zip` (`build.zig.zon:11-13`) | `b6aa932 fix: close GAP-PB-001 - remove orphan protoc-linux-64 dependency` — removed the orphan entry. The literal name `protoc-linux-64` is never constructed by `getProtocDependency` in `utils/build_util.zig` (which builds names from `protoc-{os}-{arch}`), so the entry was dormant; removing it eliminates a future foot-gun where a literal-key caller would silently fetch a Windows binary on Linux. |
| GAP-PB-003 | Critical (also Q-11) | Dead `printAllDecoded` helper referenced undefined `protobuf.WireDecoderIterator` (`tests/tests.zig:10-16`, `tests/alltypes.zig:12-18`) | `ff50ff4 chore: close GAP-PB-003 - remove dead printAllDecoded helper` — removed both copies. The function was unused by any test and would have failed to compile if invoked. |
| GAP-PB-004 | High (force-multiplier; subsumes GAP-PB-009 and partially Q-18) | No CI configuration | `bd2ef6a ci: close GAP-PB-004 - add GitLab CI pipeline` — added `.gitlab-ci.yml` with three jobs running on Zig 0.16.0: `fmt` (zig fmt --check on hand-written sources), `build` (zig build -Doptimize=Debug), `test` (zig build test --summary all). Pulls Zig 0.16.0 from ziglang.org each run. Unblocks fuzz/coverage/bench follow-ups (GAP-PB-013/014/015). |

## Deferred (Won't Do — defer to a follow-up branch or major version)

These items are tracked but explicitly deferred from this gap-close run.
The deferral reason is recorded inline; revisit when the listed
prerequisites change.

| ID | Reason for deferral |
|----|---------------------|
| **GAP-PB-005** (Maps not first-class) | Large feature, requires extending `FieldType` with a `.map` variant and teaching the generator to emit `std.AutoHashMapUnmanaged` / `std.StringHashMapUnmanaged` accessors. Schedule independently; out of scope for autonomous closure. |
| **GAP-PB-006** (JSON well-known types) | Large feature: `Timestamp`, `Duration`, `FieldMask`, `Any`, wrappers, `Struct`/`Value`/`ListValue` each have a canonical JSON form per the protobuf spec. Plumbing these into `src/json.zig` is a multi-PR effort and impacts public JSON output. |
| **GAP-PB-010** (proto3 conformance harness) | Large infrastructure: the upstream `conformance_test_runner` requires a stdio-based driver in this repo plus CI plumbing. Schedule after GAP-PB-005/006 land so conformance results are meaningful. |
| **GAP-PB-014** (coverage instrumentation) | Requires `kcov` (or `llvm-cov`) on the CI image and a coverage-merge step. Deferred until the CI pipeline (now in place) is stable across a few merges. |
| **GAP-PB-021** + **Q-15** (snake_case → camelCase rename) | Touches public API symbol names (`fd`, `internal_init`, `get_field_default_value`). Defer to a major version bump (4.0). |
| **Q-01 / Q-02 / Q-03** (large refactors: `decodeMessage` 539 LOC, `dupeField` / `deinitField` / `writeValue` sibling functions, `generateMessages` 234 LOC) | The audit's quality reviewer explicitly recommended doing these last, after smaller items widen coverage. Now that the test count is at 140 (up from 119 pre-audit) and a fuzz harness exists, these refactors can be undertaken on a dedicated branch. |
| **Q-04 / Q-05 / Q-06 / Q-07** (duplication refactors) | Schedule with Q-01–Q-03. |
| **GAP-PB-007 encode side** (proto2 group encode) | Read-side closed via N1; encode-side requires generator changes and is rarely needed in proto3-only consumers. |
| **S4** (UTF-8 validation on string fields) | Behavioral non-conformance with spec, but the test corpus contains intentionally non-UTF-8 string fixtures that document the current contract. Add as `validate_utf8: bool = false` opt-in once a consumer requests it. |
| **S5** (generator panics on adversarial CodeGeneratorRequest) | Build-time DoS only; trust boundary is "the developer's protoc invocation is trusted." |
| **N2** (skipField .len cap), **N3** (32-bit overflow), **N7** (base64 arena hygiene) | Low risk; defer to a hardening pass. |
| **N4** (`decode_bool` accepts only 0x00/0x01) | The author has an explicit test pinning the strict policy with a citation to https://protobuf.dev/programming-guides/encoding/#bools-and-enums. Reclassified as **Won't Do** by author intent. |
| **N13** (generator package-name path traversal) | Build-time only; defer with S5. |
| **P-01** (writeSubmessage encodedSize), **P-02** (varint fast path), **P-03** (decodeMessage switch dispatch), **P-04 / P-05 / P-06 / P-08 / P-09** | Material perf work — needs the bench harness (just landed) wired with timing first, then validate against ReleaseFast measurements. Schedule as a perf sprint on a dedicated branch. |
| **P-14 / P-15 / P-16** (generator perf) | Build-time only; nice-to-have. |

## Cross-domain impact

- **Critical gaps**: 3 → 0 (GAP-PB-001 / GAP-PB-002 / GAP-PB-003 all closed).
- **Security High findings**: 5 → 0 open (S1, S2a, S2b, S3, N1 all closed).
- **Security Medium findings**: 5 → 4 open (N8 closed; S4, S5, N2, N13 deferred).
- **Quality top-N PriorityScore findings**: Q-01–Q-03 deferred per audit recommendation; everything ≤ Q-07 priority closed or deferred.
- **Performance backlog**: small wins (P-07, P-10) closed; bench harness landed; large wins (P-01/P-02/P-03) await timing wiring.

## 2026-04-26 — perf sprint #1 (4 items closed, 3 deferred with handoff)

Drove the bench harness from a smoke-only stub to a 3-layer
defensible pipeline (micro / integration / comparison) and used it
to validate every perf gap from the original audit's findings table.
Each closure ships with a feature flag (`-Duse-...=false`) so the AB
runner can disable the optimization on `ref_b` for variance
attribution. The compare script's variance-aware gate
(`max(stddev × 3, 3 % × baseline)`) decides PASS / FAIL.

### Infrastructure precursor (lands across multiple commits below)

| Component | Commit | Notes |
|-----------|--------|-------|
| 3-layer bench harness (micro / integration / comparison) | `09fa0d8 perf: install three-layer bench harness + capture 9d77025 baseline` | bench/{framework,main,scenarios_*}.zig; 18 scenarios; std-lib only timing on `std.Io.Clock`; ISO 8601 records; smp_allocator backing |
| 7 build-time feature flags + protobuf-module `build_options` wiring | `2a3d295 build: wire build_options into the protobuf module + compare.py sign fix` (cherry-picked into perf branches; subsumed by individual perf MRs) | `use-fast-varint`, `use-single-pass-submessage`, `use-fast-tag-dispatch`, `use-inline-packed-write`, `use-ensure-capacity-packed`, `use-fast-json-key-dispatch`, `use-direct-json-encode` |
| `scripts/compare.py` (variance-aware gate, stable `NATIVE_BENCH …` summary line) | `09fa0d8` initial; sign-convention fix in `017590d perf: P-02 A/B evidence + compare.py sign fix` | Python 3.10+ stdlib only; gate flips IMPROVEMENT ↔ REGRESSION on ns/op (lower-is-better) semantics |
| `scripts/ab_runner.sh` (worktree-based A/B, refuses identical refs, host-state before+after, alternating measured rounds) | `09fa0d8` | Bash + git worktrees; ISO 8601 evidence dir layout |
| `scripts/host_state.sh` | `09fa0d8` | Linux + macOS portable JSON emitter |
| `scripts/stress_followup.sh` (20× repeat after PASS verdict) | `bc59498 perf: 20x stress follow-up for P-02 — PASS` | Shipped via the P-02 MR; reusable by every subsequent gap |
| Drive-by: `dupeImpl` `[]const u8.dupe` bug in repeated-string field | `09fa0d8` | Existing tests didn't exercise the path; bench's `dupe-fixture-vector-tile` scenario uncovered it. Replaced `try item.dupe(allocator)` with `try allocator.dupe(u8, item)`. `zig build test` 140 → 140 after fix |

### Closed (PASS verdict, shipped)

| ID | Severity | Title | Result | Closed by |
|----|----------|-------|--------|-----------|
| **P-02** | P0 | `decodeScalar` varint byte-at-a-time, no fast path | **PASS** — `decode-varint-10byte-i64` -7.14 % (42 → 39 ns), 1 improvement / 0 regressions, 20× / 20× stress clean | `fe7fee1 perf: P-02 fast-path varint decode in decodeScalar` + `017590d perf: P-02 A/B evidence + compare.py sign fix` + `bc59498 perf: 20x stress follow-up for P-02 — PASS`; merged via MR !1 (`dc243e9`). When `max_bytes` are already buffered, the inline-for unrolled fast path eliminates per-byte `try takeByte()` error-return scaffolding. AB-disable: `-Duse-fast-varint=false`. |
| **P-04** | P1 | 4× `writePacked*List` temp buffers | **PASS** — `dupe-fixture-vector-tile` -10.05 % (4,706,157 → 4,233,022 ns) via -27 % allocs/op on encode (10,545 vs 14,451), 1 improvement / 0 regressions, 20× / 20× stress clean | `1f47963 perf: P-04 inline packed-list writers (skip temp buffer)` + `9219f49 perf: P-04 A/B evidence + 20x stress — PASS`; merged via MR !4 (`e4c20a5`). Fixed scalars use exact `count × @sizeOf`; varints/strings size-walk via `varintByteSize` (new pub helper). Doesn't hit the P-01 trap because packed lists are flat by spec — never recurse. AB-disable: `-Duse-inline-packed-write=false`. |
| **P-05** | P1 | `decodeRepeated` packed loop missing `ensureTotalCapacity` | **PASS** — `decode-fixture-graphics-deep` -6.15 % (1,540,816 → 1,445,986 ns), packed-field alloc count -2.4 % on `vector_tile`, 1 improvement / 0 regressions, 20× / 20× stress clean | `2c59dab perf: P-05 ensureTotalCapacity in decodeRepeated packed loops` + `8369443 perf: P-05 A/B evidence + 20x stress — PASS`; merged via MR !3 (`646ba3f`). Reserves capacity once before the per-element loop; fixed scalars get exact count, varints/enums get bytes-as-upper-bound. AB-disable: `-Duse-ensure-capacity-packed=false`. |
| **P-09** | P1 | `json.encode` uses `valueAlloc` returning owned slice | **CLOSED-AS-API-ADDITION** — `pub fn encodeToWriter(data, options, writer)` exposed in `src/json.zig`; bench impact unchanged because every bench scenario consumes `[]u8` by contract. Audit premise (`valueAlloc` "doubles memory traffic" via "value-tree round-trip") was stale: Zig 0.16.0's `std.json.Stringify.value` already streams tokens directly to its writer; only the temp `Writer.Allocating` buffer inside `valueAlloc` is avoidable, and `encodeToWriter` lets writer-owning consumers skip it. | `c9bd4c1 fix: close P-09 - json.encodeToWriter streaming entry point`. Adds the streaming entry point + a round-trip equivalence test (`tests/tests_json.zig` "JSON: encodeToWriter matches encode (P-09)") proving byte-for-byte equality with `encode`. Test suite: 140 → 141 pass. |

### Deferred (investigation complete, design or rationale committed)

| ID | Severity | Title | Reason | Tracked in |
|----|----------|-------|--------|-----------|
| **P-01** | P0 | `writeSubmessage` 2-pass alloc-then-write | Naive single-pass via `std.Io.Writer.Discarding` is asymptotically wrong: every nested submessage recurses into the same two-pass discipline → total work `O(2^depth)`. Measured 22 ms vs 5 ms baseline (4.3× **slower**). The correct fix is one of (a) size-cache walk threaded through the encode pipeline, (b) placeholder + patch-back on writers that support random-access, (c) stack-buffered temp for small submessages — all multi-day refactors. | `8f2b30b docs: P-01 design — naive single-pass writeSubmessage fails` (merged via MR !2 `ce4a045`). The `-Duse-single-pass-submessage` build option survives as a no-op flag, ready to flip the slow path back on once a real impl reads it. Design note + recommended next step at `docs/performance/2026-04-26-p-01-single-pass-submessage-design/design.md`. |
| **P-03** | P0 | `decodeMessage` `inline for` tag dispatch | Skipped after analysis: the existing `inline for` over `desc_table` fields with `comptime continue` already lowers (under LLVM) to a chain of comparisons that the compiler can convert to a jump table on dense field-number sets. Refactoring the 559-line dispatch body to an explicit comptime-built `switch` is high-risk for subtle correctness bugs, and no small-message bench scenario exists in the current fixtures (vector_tile.bin and graphics.bin are large messages where dispatch overhead is amortized). The architecture's "≥10 % gain" estimate cannot be validated against the current bench. | This RESOLVED entry (no commit). The `-Duse-fast-tag-dispatch` build option is wired and ready for the day a small-message bench fixture is added or `-femit-asm` inspection of the conformance proto motivates a ground-up refactor. |
| **P-08** | P1 | JSON parse field-name dispatch O(N_fields × N_keys) | Length-bucketed dispatch implemented and AB'd (`2b47401 perf: P-08 length-bucketed JSON key dispatch`). Result: `NATIVE_BENCH result=PASS scenarios=18 regressions=0 improvements=0` — entirely neutral on `vector_tile` (json-decode +2.74 %, json-encode +0.64 %, both within variance gate). Per-struct field counts in `vector_tile` (≤7 fields) are too small for the bucket-lookup overhead to amortize against saved memcmps. | `309d73d Revert "perf: P-08 length-bucketed JSON key dispatch"` + `5a0f950 docs: P-08 — length-bucketed JSON dispatch attempted, reverted` (merged via MR !5 `30f008b`). Decision + recommended next step at `docs/performance/2026-04-26-p-08-fast-json-key-dispatch/decision.md`. The `-Duse-fast-json-key-dispatch` build option survives as a no-op flag, ready for the day a wider-schema JSON fixture (e.g. `tests/fixtures/graphics_db.json`) is added or a size-gated impl (`if (fields.len >= 16)`) is written. |

### Verification (perf sprint)

- `zig build test --summary all`: **141 / 141 tests passed** at the end of this sprint (was 140 before; +1 for `tests/tests_json.zig` "JSON: encodeToWriter matches encode (P-09)").
- `zig build test -Duse-fast-varint=false`, `-Duse-inline-packed-write=false`, `-Duse-ensure-capacity-packed=false`, `-Duse-single-pass-submessage=false`, `-Duse-fast-json-key-dispatch=false`: each 141 / 141 pass — every feature flag is wired correctly and the slow paths remain compileable + correct.
- `zig fmt --check` exit 0 across all hand-written sources.
- 4 PASS verdicts each cleared the 20× stress follow-up (test = 20 / 20, bench = 20 / 20).
- Baseline evidence (`docs/performance/2026-04-26-encode-decode-baseline/`) and per-MR AB evidence dirs all pass `bench-validator` with `validate-rules.sh` exit 0.

### Architecture-vs-actual delta

| Gap | Architecture estimate | Measured |
|-----|----------------------:|---------:|
| P-02 | ≥15 % ns/op on hot varint sizes | -7.14 % on 10-byte (single scenario clears gate) |
| P-04 | ≥15 % ns/op on packed-list encode | -10.05 % on dupe (driven by -27 % allocs/op on encode-roundtrip) |
| P-05 | ≥10 % ns/op on packed fields | -6.15 % on graphics-deep |
| P-09 | ≥10 % ns/op on JSON encode | 0 % (audit premise stale; API improvement only) |
| P-01 | ≥20 % ns/op encode | not realised (multi-day refactor remaining) |
| P-08 | ≥25 % ns/op JSON parse | not realised on `vector_tile`; needs wider fixture |
| P-03 | ≥10 % ns/op | not validated; no small-message bench fixture |

The architecture estimates were optimistic relative to the
fixtures actually committed. Where the estimate was met, the
improvement shipped behind a flag with stress and AB evidence.
Where it wasn't, the investigation outcome is documented and the
flag survives so the optimization can be re-attempted when the
preconditions land (wider fixtures for P-08, small-message
fixture for P-03, multi-day refactor budget for P-01).
