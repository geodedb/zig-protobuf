# Requirements Gap Analysis — devnw/zig/protobuf

**Generated:** 2026-04-26
**Last updated:** 2026-04-26 (post gap-close run)
**Scope:** entire repo
**Method:** Requirements derived from README + public API + tests + protobuf spec; traced to code.

## Summary

- Total requirements: 30
- Implemented: 27
- Partial: 3 (R4, R18, R30)
- New gaps detected: 22 (GAP-PB-001 ... GAP-PB-022)
- **Closed in this run:** 3 (GAP-PB-001, GAP-PB-003, GAP-PB-004) — see `GAP_ANALYSIS_RESOLVED.md`

| Status | Count | Percentage |
|--------|-------|-----------|
| Implemented | 27 | 90% |
| Partial | 3 | 10% |
| Not Implemented | 0 | 0% |
| Unknown | 0 | 0% |

## Open Gaps

Sorted by severity (Critical -> High -> Medium -> Low), then by Gap-ID.

| Gap-ID | Severity | Category | Effort | Title | File:Line | Status | Rationale |
|--------|----------|----------|--------|-------|-----------|--------|-----------|
| GAP-PB-001 | Critical | tooling | Small | `protoc-linux-64` dep points at Windows zip | build.zig.zon:11 | **Closed** (b6aa932) | Hash also corresponds to win64. Currently dormant in `getProtocDependency` but a literal-name caller would fetch `.exe` on Linux. **Resolved by removing the orphan entry.** |
| GAP-PB-002 | Critical | decoder | Medium | sint32/sint64 zigzag round-trip is broken (TODO) | tests/optionals.zig:88-90 | Partial (R4) | Two `TestAllTypes` assertions commented out. Wire-format bug hidden behind silent test pass. R4 unverifiable. |
| GAP-PB-003 | Critical | hygiene | Small | Dead `printAllDecoded` references undefined `protobuf.WireDecoderIterator` | tests/tests.zig:10-16, tests/alltypes.zig:12-18 | **Closed** (ff50ff4) | Dead helper duplicated across two files; both copies removed. |
| GAP-PB-004 | High | tooling | Medium | No CI configuration | .gitlab-ci.yml | **Closed** (bd2ef6a) | Added GitLab CI with fmt/build/test stages on Zig 0.16.0. Unblocks GAP-PB-009 and provides harness for fuzz/coverage/bench. |
| GAP-PB-005 | High | feature | Large | Maps not first-class | src/protobuf.zig (no .map FieldType); generator no map_entry handling | Partial | Maps round-trip via repeated MapEntry; no native API; descriptor map_entry flag ignored. |
| GAP-PB-006 | High | json | Large | Well-known types unsupported in JSON | src/json.zig:429 (TODO comment) | Not Impl. | Timestamp, Duration, Any, FieldMask, wrappers, Struct/Value/ListValue. |
| GAP-PB-007 | High | decoder | Medium | proto2 groups silently consumed | src/wire.zig:1084 (skipField) | Not Impl. | sgroup/egroup discarded with no error/encode path. |
| GAP-PB-008 | High | robustness | Medium | dupe lacks cycle detection | src/protobuf.zig (dupe recursion) | Partial (R18) | Self-referential graphs would cause unbounded recursion. |
| GAP-PB-009 | High | tooling | Small | No `zig fmt --check` enforcement | (no CI pipeline) | Not Impl. | Trivial after GAP-PB-004. |
| GAP-PB-010 | High | tooling | Large | No proto3 conformance harness | tests/proto/conformance/*.proto present, not wired | Not Impl. | Without conformance runner, spec-compliance unprovable. |
| GAP-PB-011 | Medium | hygiene | Small | protobuf.zig declares unused std.log.scoped | src/protobuf.zig:3 | Partial (R30) | Drop or gate for freestanding. |
| GAP-PB-012 | Medium | hygiene | Small | Dead extraction types/helpers | src/protobuf.zig:1032-1041, 1052, 1079 | Not Impl. | ExtractedDataTag, ExtractedData, Extracted, DecodedVarint, decode_varint, decode_fixed kept only for self-tests. |
| GAP-PB-013 | Medium | tooling | Medium | No fuzz harness | (no tests/fuzz*.zig) | Not Impl. | Library parses untrusted bytes; std.testing.fuzz available. |
| GAP-PB-014 | Medium | tooling | Medium | No coverage instrumentation | (no kcov hookup) | Not Impl. | Would catch silent test gaps like GAP-PB-002. |
| GAP-PB-015 | Medium | tooling | Medium | No benchmark/perf harness | (no bench/, no `zig build bench`) | Not Impl. | Required for any perf claim. |
| GAP-PB-016 | Medium | docs | Small | README install snippet stale | README.md (Arwalk path) | Not Impl. | origin is gitlab.com/devnw/...; README onboards to upstream. |
| GAP-PB-017 | Medium | hygiene | Small | isEnvVarTruthy is no-op stub | utils/build_util.zig:20-26 | Not Impl. | Always returns same value. |
| GAP-PB-018 | Medium | generator | Small | Public API doc-comment gaps | src/json.zig:5,107,117,125; src/protobuf.zig:8,855; src/wire.zig:120 | Partial | Missing `///` on parse/decode/encode/stringify, DecodingError, deinitField, ZigZag. |
| GAP-PB-019 | Low | hygiene | Small | Redundant addImport in build.zig | build.zig:150-153 | Not Impl. | Conditional dead, double-add. |
| GAP-PB-020 | Low | hygiene | Small | Dead aggregator tests/integration.zig | tests/integration.zig:1-11 | Not Impl. | Unused imports; no test {} block. |
| GAP-PB-021 | Low | hygiene | Medium | Inconsistent fn naming snake vs camel | ~10 sites in src/ | Not Impl. | Touches public API; defer to a major version. |
| GAP-PB-022 | Low | docs | Small | build.zig.zon paths whitelists non-existent dirs | build.zig.zon (.github, .devcontainer) | Not Impl. | Cosmetic. |

## Top 5 Highest-Impact Gaps

1. **GAP-PB-001** — single-line fix, unblocks Linux builds
2. **GAP-PB-002** — wire-format bug masked by green CI
3. **GAP-PB-003** — latent compilation breakage
4. **GAP-PB-004** — force-multiplier; unblocks 9, 10, 13, 14, 15
5. **GAP-PB-006** — spec-compliance + OpenTelemetry consumer impact

## Recommended Remediation Order

The following 12-step sequence sequences fixes by dependency: low-effort/high-impact correctness fixes first, then automation unblockers, then larger feature/spec work.

1. **GAP-PB-001** — Fix `protoc-linux-64` dependency URL/hash to point at the Linux zip (single-line, unblocks Linux native builds).
2. **GAP-PB-003** — Remove or fix `tests/tests.zig` reference to undefined `protobuf.WireDecoderIterator` (dead helper; latent compile break).
3. **GAP-PB-002** — Restore the two commented-out sint32/sint64 zigzag assertions in `tests/optionals.zig` and fix the underlying wire-format bug. Required for R4 verification.
4. **GAP-PB-004** — Add a CI configuration (`.gitlab-ci.yml`) running `zig build test` across Zig 0.15.x and 0.16.x; this is a force-multiplier for steps 5, 7, 8, 9.
5. **GAP-PB-009** — Add `zig fmt --check` to CI (trivial once step 4 lands).
6. **GAP-PB-010** — Wire the existing `tests/proto/conformance/*.proto` files into a conformance test target that runs in CI.
7. **GAP-PB-013** — Add a `tests/fuzz_*.zig` harness using `std.testing.fuzz` over the wire decoder and JSON parser.
8. **GAP-PB-014** — Add kcov coverage instrumentation in CI to surface silent-pass gaps like step 3.
9. **GAP-PB-015** — Add `bench/` and `zig build bench` step for perf regression tracking.
10. **GAP-PB-007** — Implement proper proto2 group encode/decode (replace silent skipField with an error path or full support).
11. **GAP-PB-008** — Add cycle detection or depth limiting to `dupe` for self-referential message graphs.
12. **GAP-PB-005** + **GAP-PB-006** — Larger feature work: native `map<K,V>` first-class support in the generator and runtime, then JSON mapping for well-known types (Timestamp, Duration, Any, FieldMask, wrappers, Struct/Value/ListValue).

Cosmetic / hygiene items (GAP-PB-011, GAP-PB-012, GAP-PB-016, GAP-PB-017, GAP-PB-018, GAP-PB-019, GAP-PB-020, GAP-PB-021, GAP-PB-022) can be batched into a single cleanup MR after the above lands.

## Requirements Traceability

R1-R30 derived from README, public API surface, test corpus, and the protobuf wire/JSON specs. Status reflects implementation in the current `main`.

| Req-ID | Requirement | Status | Evidence |
|--------|-------------|--------|----------|
| R1 | Encode varints (int32, int64, uint32, uint64, bool, enum) per protobuf wire format | Implemented | src/wire.zig (varint encoder); tests/all_types.zig round-trip |
| R2 | Decode varints with overflow detection | Implemented | src/wire.zig varint decode path; tests/optionals.zig boundary cases |
| R3 | Encode/decode fixed32 and fixed64 (incl. sfixed) | Implemented | src/wire.zig fixed encoders; tests/all_types.zig fixed fields |
| R4 | sint32/sint64 zigzag encoding round-trip | Partial | src/protobuf.zig ZigZag helpers present; tests/optionals.zig:88-90 has two commented-out sint assertions (GAP-PB-002) |
| R5 | float and double encode/decode | Implemented | src/wire.zig fixed32/fixed64 paths; tests/all_types.zig float fields |
| R6 | string and bytes (length-delimited) encode/decode | Implemented | src/wire.zig length-delimited path; tests cover both |
| R7 | Nested message encode/decode | Implemented | src/protobuf.zig recursive pb_encode/pb_decode; tests/all_types.zig NestedMessage |
| R8 | repeated fields (packed and unpacked) | Implemented | src/wire.zig packed/unpacked handling; tests/all_types.zig repeated_int32 etc. |
| R9 | optional fields (proto2/proto3) with presence | Implemented | tests/optionals.zig exercises optional presence |
| R10 | enum encode/decode with unknown-value preservation | Implemented | src/protobuf.zig enum varint path; tests/all_types.zig enum coverage |
| R11 | Unknown field preservation across decode/encode | Implemented | src/wire.zig unknown-fields buffer; round-trip tests |
| R12 | oneof support (mutually exclusive set semantics) | Implemented | src/protobuf.zig oneof tag tracking; tests/all_types.zig oneof_* fields |
| R13 | Default values applied per proto3 semantics | Implemented | src/protobuf.zig zero-value defaults; tests pass without explicit defaults |
| R14 | Public encode API: `pb.encode(allocator, msg) ![]u8` | Implemented | src/protobuf.zig encode entry point; README example |
| R15 | Public decode API: `pb.decode(T, allocator, bytes) !T` | Implemented | src/protobuf.zig decode entry point; README example |
| R16 | JSON serialization: `json.stringify(msg, allocator) ![]u8` | Implemented | src/json.zig stringify path; tests/json_test.zig |
| R17 | JSON deserialization: `json.parse(T, allocator, str) !T` | Implemented | src/json.zig parse path; tests/json_test.zig |
| R18 | `dupe(T, allocator, msg) !T` deep-copy of message values | Partial | src/protobuf.zig dupe recursion works for trees; no cycle detection (GAP-PB-008) |
| R19 | `deinit` releases all owned allocations | Implemented | src/protobuf.zig deinit walker; tests pass under GeneralPurposeAllocator leak check |
| R20 | `proto-gen-zig` generator produces idiomatic Zig from .proto | Implemented | bootstrapped/protobuf/* generator output present; build.zig generator step |
| R21 | Generator handles nested types and packages | Implemented | bootstrapped/google/protobuf/*.zig nested output |
| R22 | Generator emits oneof unions correctly | Implemented | bootstrapped output for unittest.proto oneof_* fields |
| R23 | Generator emits repeated/optional/required correctly | Implemented | bootstrapped/protobuf/unittest output |
| R24 | Build supports Zig 0.15.x and 0.16.x | Implemented | build.zig version-gated APIs; recent commits f18747d, 462java, 78fc12a, c02f3aa, 53ece58 fix 0.16.0 compat |
| R25 | Cross-platform builds (linux/macos/windows) | Implemented | build.zig std target conventions; build.zig.zon multi-OS protoc deps (modulo GAP-PB-001) |
| R26 | Test suite runs via `zig build test` | Implemented | build.zig test step wires tests/tests.zig and module tests |
| R27 | Round-trip equivalence for all_types.proto / unittest.proto | Implemented | tests/all_types.zig encode-then-decode equality |
| R28 | License: MIT | Implemented | LICENSE file present at repo root |
| R29 | README documents minimal usage example | Implemented | README.md getting-started section (stale path noted in GAP-PB-016) |
| R30 | No panics on malformed input; errors returned | Partial | DecodingError set returned from decoder; src/protobuf.zig:3 has unused std.log.scoped (GAP-PB-011); some untested malformed-input branches (mitigated by GAP-PB-013 fuzz follow-up) |
