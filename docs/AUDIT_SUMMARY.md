# Full Codebase Audit Summary — devnw/zig/protobuf

**Generated:** 2026-04-26
**Last updated:** 2026-04-26 (post gap-close runs #1 + #2; 24 items closed across 21 commits)
**Scope:** entire repo
**Mode:** `--skip-issues` (GitLab platform; no issues created)
**Audit Domains:** Gap Analysis · Code Quality · Performance · Security

## Closed Across Two Gap-Close Runs

24 items closed across 21 commits — see `GAP_ANALYSIS_RESOLVED.md` for full per-item detail.

### Gap-close run #1 (5 items)

| ID | Severity | Title | Commit |
|----|----------|-------|--------|
| S3 | High (Risk 140) | Duplicate `errdefer` double-free in `repeated bytes`/`string` decode | `b88d845` |
| GAP-PB-001 | Critical | `protoc-linux-64` dependency points at Windows zip | `b6aa932` |
| GAP-PB-003 | Critical | Dead `printAllDecoded` references undefined `WireDecoderIterator` | `ff50ff4` |
| N1 | High (Risk 84) | `skipField` sgroup/egroup CPU infinite loop | `92c5a59` |
| GAP-PB-004 | High | No CI configuration → added `.gitlab-ci.yml` | `bd2ef6a` |

### Gap-close run #2 (19 items, ~24 incl. cross-references)

| ID | Severity | Title | Commit |
|----|----------|-------|--------|
| GAP-PB-011 | Medium | Unused `std.log.scoped` declaration | `423c0be` |
| GAP-PB-012 + Q-09 + Q-10 | Medium | Dead extraction types and helpers | `f6f3295` |
| GAP-PB-016 | Medium | README install snippet stale | `29c4e70` |
| GAP-PB-017 + Q-08 | Medium | `isEnvVarTruthy` no-op stub | `ec9cfe0` |
| GAP-PB-019 + Q-12 | Medium | build.zig redundant addImport + unused imports | `7a60988` |
| GAP-PB-020 + Q-13 | Low | tests/integration.zig unused imports | `10f030f` |
| GAP-PB-022 + Q-20 | Low | build.zig.zon paths whitelist non-existent dirs | `364d66a` |
| Q-14 | Low | Unused `warn` import in main.zig | `713a0a8` |
| GAP-PB-018 + Q-16 + Q-17 | Medium | Public API doc-comment gaps | `2ce5282` |
| N8 | Medium (CWE-20) | `Tag.decode` rejects field 0 | `a13c854` |
| GAP-PB-002 | Critical | sint32/sint64 zigzag round-trip TODO (decoder was correct; TODO had wrong values) | `5076601` |
| Q-19 + S7 | Low | SECURITY.md, CONTRIBUTING.md, CHANGELOG.md, .editorconfig | `be33345` |
| S1 + S2a + S2b | High (CWE-674, 789) | Decode hardening (max_depth, max_alloc_per_field, max_elements) | `1e171cc` |
| GAP-PB-008 | High | `dupe` cycle detection (max_dupe_depth) | `f3e9785` |
| P-07 + P-10 | P1, P2 | Stack-buffer varint/fixed write; appendAssumeCapacity | `40ffe07` |
| GAP-PB-013 + GAP-PB-015 + P-11/12/13 + N16 | Medium / Info | Bench harness + fuzz harness | `913e626` |

**Post-run state:** 140/140 tests pass; 0 regressions. **Critical gaps:** 3 → 0. **Security High findings:** 5 → 0 open. Coverage / large refactors / large feature work explicitly deferred (see `GAP_ANALYSIS_RESOLVED.md` § "Deferred").

## Repository

- **Project:** zig-protobuf
- **Platform:** GitLab (`git@gitlab.com:devnw/zig/protobuf.git`)
- **Languages:** Zig (min 0.15.1; recent commits migrated to 0.16.0)
- **Type:** Pure encode/decode library + `protoc-gen-zig` plugin
- **Branch:** main
- **Build:** `zig build test` PASS (~1.42s wall, Debug)

### Inventory

| Component | Path | LOC |
|---|---|---|
| Core library | `src/{protobuf,wire,json}.zig` | 2,886 |
| Generator | `bootstrapped-generator/{main,FullName}.zig` | 1,091 |
| Bootstrapped descriptors | `bootstrapped-generator/google/*.pb.zig` | 3,200 (generated) |
| Hand-written tests | `tests/*.zig` | 2,494 |
| Generated test outputs | `tests/{generated,.generated}/*.pb.zig` | 25,309 (generated) |
| Build helpers | `build.zig`, `utils/build_util.zig` | 435 |

## Domain Results

### Gap Analysis

| Status | Count | Percentage |
|--------|-------|------------|
| Implemented | 27 | 90% |
| Partial | 3 | 10% |
| Not Implemented | 0 | 0% |
| Unknown | 0 | 0% |

**Open gaps:** 22 (Critical: 3, High: 7, Medium: 8, Low: 4)
**Top gap (severity):** GAP-PB-001 — `protoc-linux-64` dep points at Windows zip (`build.zig.zon:11`)

### Code Quality

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 3 |
| Medium | 9 |
| Low | 9 |

**PriorityScore top finding:** Q-02 — sibling proto-type-matrix functions in `src/protobuf.zig` (`dupeField`, `deinitField`, `writeValue`, each 100–175 LOC; PriorityScore 37.33). Q-01 (`decodeMessage` 539-LOC mega-function) close behind at 35.00.

### Performance

| PerfSeverity | Count |
|--------------|-------|
| P0 | 3 |
| P1 | 6 |
| P2 | 1 |
| P3 | 6 (3 infra + 3 generator) |

**PerfScore top finding (tie at 750.0):**
- P-01 — `writeSubmessage` 2-pass alloc-then-write (`src/protobuf.zig:261-274`)
- P-02 — `decodeScalar` varint byte-at-a-time, no fast path (`src/wire.zig:202-262`)

**Baseline:** `zig build test` Debug 1.42s wall on this host. ReleaseFast not yet captured. No bench harness exists (`tests/fixtures/graphics.bin` 1.1 MB and `vector_tile.bin` 125 KB sit unused for perf measurement).

### Security

| Risk Level | Count |
|------------|-------|
| Critical | 0 |
| High | 5 |
| Medium | 5 |
| Low | 5 |
| Info | 1 |

**Immediate actions:** 1 (S3 1-line double-free fix at `src/wire.zig:408`)
**No secrets** found; no platform issues created. Clean dependency surface (8 protoc binaries, all hash-pinned, lazy=true).

**Risk Score top finding:** S3 — duplicate `errdefer allocator.free(bytes)` in `decodeRepeated` slice path → double-free / heap-corruption primitive (Risk Score 140; next highest N1 at 84).

## Cross-Domain Summary

| Domain | Findings | Issues Created | Issues Updated | Issues Closed |
|--------|----------|----------------|----------------|---------------|
| Gap Analysis | 22 | 0 (skip-issues) | 0 | 0 |
| Quality | 21 | 0 (skip-issues) | 0 | 0 |
| Performance | 16 | 0 (skip-issues) | 0 | 0 |
| Security | 16 | 0 (skip-issues) | 0 | 0 |
| **Total** | **75** | **0** | **0** | **0** |

## Docs Updated

| File | Domain | Action |
|------|--------|--------|
| `docs/GAP_ANALYSIS.md` | Gap | created (22 gaps + R1-R30 traceability) |
| `docs/QUALITY_GAP_ANALYSIS.md` | Quality | created (21 findings, PriorityScore-ranked) |
| `docs/PERF_GAP_ANALYSIS.md` | Performance | created (16 findings, PerfScore-ranked, bench skeleton) |
| `docs/SECURITY_GAP_ANALYSIS.md` | Security | created (16 findings, Risk-Score-ranked, threat model) |
| `docs/AUDIT_SUMMARY.md` | All | this file |

## Top 10 Findings (cross-domain, by impact)

| # | Domain | ID | Finding | Severity | Score |
|---|--------|----|---------|----------|-------|
| 1 | Security | **S3** | Duplicate `errdefer` in `decodeRepeated` slice path → double-free (`src/wire.zig:406-410`) | High | Risk 140 |
| 2 | Security | **S1** | Unbounded recursion in `decodeMessage` → stack-overflow DoS | High | Risk 84 |
| 3 | Security | **S2a/b** | No alloc cap on length-prefix; no element-count cap on packed/repeated → OOM DoS | High | Risk 84 |
| 4 | Security | **N1** | `sgroup`/`egroup` consumed=0 in `skipField` → CPU infinite loop on malformed input (`src/wire.zig:1084`) | High | Risk 84 |
| 5 | Gap | **GAP-PB-001** | `protoc-linux-64` dep URL points at Windows zip (`build.zig.zon:11`) | Critical | — |
| 6 | Gap | **GAP-PB-002** | sint32/sint64 zigzag round-trip TODO; assertions commented out, R4 unverifiable (`tests/optionals.zig:88-90`) | Critical | — |
| 7 | Gap | **GAP-PB-003** | `tests/tests.zig:11` references undefined `protobuf.WireDecoderIterator` | Critical | — |
| 8 | Gap | **GAP-PB-004** | No CI configuration; force-multiplier unblocking 9, 10, 13, 14, 15 | High | — |
| 9 | Perf | **P-01/P-02** | `writeSubmessage` 2-pass alloc + `decodeScalar` byte-at-a-time varint (tied) | P0 | PerfScore 750 |
| 10 | Quality | **Q-01/Q-02** | `decodeMessage` 539-LOC mega-function; `dupeField`/`deinitField`/`writeValue` 100–175 LOC sibling type-matrix walks | High | PriorityScore 35–37 |

## Recommended Sequencing

### Week 1 — Critical fixes (mostly tiny patches)

1. **S3** — delete duplicate `errdefer` at `src/wire.zig:408` (1 line, eliminates heap-corruption primitive)
2. **GAP-PB-001** — fix `protoc-linux-64` URL+hash in `build.zig.zon` (or remove the orphan entry)
3. **GAP-PB-003** — remove dead `printAllDecoded` helper in `tests/tests.zig:10-16`
4. **GAP-PB-002** — diagnose and fix sint zigzag round-trip; re-enable assertions in `tests/optionals.zig`
5. **N1** — `skipField` returns `error.InvalidInput` on `sgroup`/`egroup` (or implement groups)

### Week 2 — Wire-decoder hardening

6. **S1** — add `DecodeOptions{ .max_depth: u32 = 100 }` thread through `decodeMessage`
7. **S2a/b** — add `max_alloc_per_field`, `max_total_alloc`, `max_elements` to `DecodeOptions`
8. **N8** — `Tag.decode` reject `field == 0`
9. **N13** — generator validate `package` against safe identifier regex

### Week 3 — CI, bench, fuzz infrastructure

10. **GAP-PB-004 + GAP-PB-009** — `.gitlab-ci.yml` running `zig fmt --check` + `zig build test` on Zig 0.15.1 / 0.16.0 matrix
11. **P-11 + P-12 + P-13** — `bench/` harness with counting allocator, `zig build bench -Doptimize=ReleaseFast` step against `graphics.bin` / `vector_tile.bin`
12. **GAP-PB-013** — `std.testing.fuzz` harness for `protobuf.decode`

### Sprint 2+ — Perf wins (validated against bench from Step 11)

13. **P-02** — varint 1-byte fast path in `decodeScalar` (~30 LOC, ~10–20% decode improvement)
14. **P-01** — `encodedSize(T)` + single-pass submessage encode (~200 LOC, encode 30–60% + alloc-count –99%)
15. **P-03** — comptime `switch` field-number dispatch in `decodeMessage` (Zig 0.16 syntax permitting)
16. **P-04, P-05, P-07, P-10** — batch (packed list direct-write, ensureTotalCapacity, stack-buffer varint/fixed write, appendAssumeCapacity)

### Sprint 3+ — Feature/conformance gaps

17. **GAP-PB-008** — cycle detection in `dupe` (key on pointer set)
18. **GAP-PB-007** — proper proto2 group encode/decode (or explicit reject)
19. **GAP-PB-005** — first-class maps (FieldType.map + generator MapEntry handling)
20. **GAP-PB-006** — JSON well-known types (Timestamp, Duration, FieldMask, Any, wrappers, Struct/Value/ListValue)
21. **GAP-PB-010** — wire `tests/protos_for_test/test_messages_proto3.proto` to upstream protobuf conformance runner

### Hygiene sweep (one PR)

22. **GAP-PB-011, GAP-PB-012, GAP-PB-016, GAP-PB-017, GAP-PB-019, GAP-PB-020, GAP-PB-022, Q-08, Q-12, Q-13, Q-14, Q-19** — dead code, stale docs, missing CONTRIBUTING.md/SECURITY.md/CHANGELOG.md/.editorconfig
23. **GAP-PB-021 (Q-15)** — defer snake_case→camelCase rename to a major-version bump

## Blockers

- **GitLab platform integration not used.** Audit ran in `--skip-issues` mode; no GitLab issues created/updated. To track findings on the platform, run `glab issue create` or use the GitLab MCP if available.
- **No ReleaseFast baseline.** All perf claims rest on Debug numbers + Phase-3 review estimates until P-11/P-12 lands.
- **No fuzz coverage.** Wire decoder is the highest-risk surface; without `std.testing.fuzz` runs, Phase-3 security findings rest on manual review.

## Highest-Leverage Single Fix

**Fix S3 first.** It's a 1-line patch (delete `src/wire.zig:408`) that eliminates a heap-corruption / double-free primitive reachable on `repeated bytes` / `repeated string` decode under append-OOM — a condition trivially induced by the S2a/S2b allocation-amplification flaws on the same code path. Highest value-per-byte-of-diff in the entire backlog.
