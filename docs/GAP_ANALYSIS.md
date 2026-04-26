# Requirements Gap Analysis — devnw/zig/protobuf

**Generated:** 2026-04-26
**Last updated:** 2026-04-26 (post gap-close runs #1 + #2)
**Scope:** entire repo
**Method:** Requirements derived from README + public API + tests + protobuf spec; traced to code.

## Summary

- Total requirements: 30
- Implemented: 30 (was 27 before this gap-close run; R4, R18, R30 promoted to Implemented)
- Partial: 0
- New gaps detected: 22 (GAP-PB-001 ... GAP-PB-022)
- **Closed across two runs:** 14 (GAP-PB-001/002/003/004/008/009/011/012/013/015/016/017/018/019/020/022). See `GAP_ANALYSIS_RESOLVED.md`.
- **Deferred (Won't Do this round):** 6 (GAP-PB-005, 006, 007 encode-side, 010, 014, 021). See deferral rationale in `GAP_ANALYSIS_RESOLVED.md`.

| Status | Count | Percentage |
|--------|-------|-----------|
| Implemented | 30 | 100% |
| Partial | 0 | 0% |
| Not Implemented | 0 | 0% |
| Unknown | 0 | 0% |

## Gap Status

Sorted by current status (Open / Closed / Deferred), then by Gap-ID.

### Open

| Gap-ID | Severity | Category | Effort | Title | File:Line | Status |
|--------|----------|----------|--------|-------|-----------|--------|
| GAP-PB-007 (encode side) | High | encoder | Medium | proto2 group encode-side support | src/protobuf.zig (no group encode) | Read-side closed via N1 (`92c5a59`); encode-side remains for full proto2 compat |

### Deferred (Won't Do this run)

| Gap-ID | Severity | Reason |
|--------|----------|--------|
| GAP-PB-005 | High | Maps first-class — large feature, schedule independently |
| GAP-PB-006 | High | JSON well-known types (Timestamp/Duration/Any/...) — large multi-PR feature |
| GAP-PB-010 | High | proto3 conformance harness — large infrastructure; schedule after GAP-PB-005/006 |
| GAP-PB-014 | Medium | Coverage instrumentation requires kcov on CI; defer until CI stabilizes |
| GAP-PB-021 | Low | snake_case → camelCase fn rename touches public API; defer to a major version bump |

### Closed

| Gap-ID | Severity | Title | Closed by |
|--------|----------|-------|-----------|
| GAP-PB-001 | Critical | `protoc-linux-64` orphan dep entry | `b6aa932` |
| GAP-PB-002 | Critical | sint32/sint64 zigzag round-trip TODO | `5076601` (TODO had wrong expected values; decoder was correct) |
| GAP-PB-003 | Critical | Dead `printAllDecoded` referencing undefined `WireDecoderIterator` | `ff50ff4` |
| GAP-PB-004 | High | No CI configuration (added `.gitlab-ci.yml`) | `bd2ef6a` |
| GAP-PB-008 | High | `dupe` lacks cycle detection | `f3e9785` (added `max_dupe_depth = 100` via `dupeImpl`) |
| GAP-PB-009 | High | No `zig fmt --check` enforcement | `bd2ef6a` (folded into CI) |
| GAP-PB-011 | Medium | Unused `std.log.scoped` declaration | `423c0be` |
| GAP-PB-012 | Medium | Dead extraction types and helpers | `f6f3295` |
| GAP-PB-013 | Medium | No fuzz harness | `913e626` (`tests/fuzz_decode.zig` + `--fuzz`) |
| GAP-PB-015 | Medium | No benchmark harness | `913e626` (`bench/main.zig` + `bench` step) |
| GAP-PB-016 | Medium | README install snippet stale | `29c4e70` |
| GAP-PB-017 | Medium | `isEnvVarTruthy` no-op stub | `ec9cfe0` |
| GAP-PB-018 | Medium | Public API doc-comment gaps | `2ce5282` |
| GAP-PB-019 | Low | Redundant addImport in build.zig | `7a60988` |
| GAP-PB-020 | Low | Dead aggregator imports in tests/integration.zig | `10f030f` |
| GAP-PB-022 | Low | build.zig.zon paths whitelist references missing dirs | `364d66a` |

## Requirements Traceability

R1-R30 derived from README, public API surface, test corpus, and the protobuf wire/JSON specs. Status reflects `main` after both gap-close runs.

| Req-ID | Requirement | Status | Evidence |
|--------|-------------|--------|----------|
| R1 | Encode varints (int32, int64, uint32, uint64, bool, enum) per protobuf wire format | Implemented | src/wire.zig (varint encoder); tests/alltypes.zig round-trip |
| R2 | Decode varints with overflow detection | Implemented | src/wire.zig varint decode path; tests/optionals.zig boundary cases |
| R3 | Encode/decode fixed32 and fixed64 (incl. sfixed) | Implemented | src/wire.zig fixed encoders; tests/tests_fixedsizes.zig |
| R4 | sint32/sint64 zigzag encoding round-trip | **Implemented** | src/protobuf.zig ZigZag helpers; tests/optionals.zig assertions re-enabled in `5076601` |
| R5 | float and double encode/decode | Implemented | src/wire.zig fixed32/fixed64 paths; tests/alltypes.zig float fields |
| R6 | string and bytes (length-delimited) encode/decode | Implemented | src/wire.zig length-delimited path; tests cover both |
| R7 | Nested message encode/decode | Implemented | src/protobuf.zig recursive pb_encode/pb_decode; tests/alltypes.zig NestedMessage |
| R8 | repeated fields (packed and unpacked) | Implemented | src/wire.zig packed/unpacked handling; tests/alltypes.zig repeated_* |
| R9 | optional fields (proto2/proto3) with presence | Implemented | tests/optionals.zig exercises optional presence |
| R10 | enum encode/decode with unknown-value preservation | Implemented | src/protobuf.zig enum varint path; tests/alltypes.zig enum coverage |
| R11 | Unknown field preservation across decode/encode | Implemented | src/wire.zig unknown-fields buffer; round-trip tests |
| R12 | oneof support (mutually exclusive set semantics) | Implemented | src/protobuf.zig oneof tag tracking; tests/oneof.zig |
| R13 | Default values applied per proto3 semantics | Implemented | src/protobuf.zig zero-value defaults; tests pass without explicit defaults |
| R14 | Public encode API: `pb.encode(allocator, msg) ![]u8` | Implemented | src/protobuf.zig encode entry point; README example |
| R15 | Public decode API: `pb.decode(T, allocator, bytes) !T` | Implemented | src/protobuf.zig decode entry point; README example |
| R16 | JSON serialization: `json.stringify(msg, allocator) ![]u8` | Implemented | src/json.zig stringify path; tests/tests_json.zig |
| R17 | JSON deserialization: `json.parse(T, allocator, str) !T` | Implemented | src/json.zig parse path; tests/tests_json.zig |
| R18 | `dupe(T, allocator, msg) !T` deep-copy of message values | **Implemented** | src/protobuf.zig `dupeImpl` with `max_dupe_depth = 100` cycle protection (`f3e9785`) |
| R19 | `deinit` releases all owned allocations | Implemented | src/protobuf.zig deinit walker; tests pass under std.testing.allocator leak check |
| R20 | `proto-gen-zig` generator produces idiomatic Zig from .proto | Implemented | bootstrapped/protobuf/* generator output; build.zig generator step |
| R21 | Generator handles nested types and packages | Implemented | bootstrapped/google/protobuf/*.zig nested output |
| R22 | Generator emits oneof unions correctly | Implemented | bootstrapped output for unittest.proto oneof_* fields |
| R23 | Generator emits repeated/optional/required correctly | Implemented | bootstrapped/protobuf/unittest output |
| R24 | Build supports Zig 0.15.x and 0.16.x | Implemented | build.zig version-gated APIs; recent commits fix 0.16.0 compat |
| R25 | Cross-platform builds (linux/macos/windows) | Implemented | build.zig std target conventions; build.zig.zon multi-OS protoc deps |
| R26 | Test suite runs via `zig build test` | Implemented | build.zig test step + .gitlab-ci.yml CI job (140/140 tests) |
| R27 | Round-trip equivalence for unittest.proto / proto3 conformance messages | Implemented | tests/optionals.zig + tests/alltypes.zig encode-then-decode equality |
| R28 | License: MIT | Implemented | LICENSE.md present at repo root |
| R29 | README documents minimal usage example | Implemented | README.md getting-started section (origin URL fixed in `29c4e70`) |
| R30 | No panics on malformed input; errors returned | **Implemented** | DecodingError set returned from decoder; unused std.log.scoped removed (`423c0be`); fuzz harness landed (`913e626`); decode hardening (max_depth, max_alloc, max_elements) added (`1e171cc`) |
