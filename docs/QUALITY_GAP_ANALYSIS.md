# Code Quality Gap Analysis — devnw/zig/protobuf

**Generated:** 2026-04-26
**Last updated:** 2026-04-26 (post gap-close run)
**Scope:** entire repo

## Summary

| Severity | Open | Closed | Total |
|----------|------|--------|-------|
| Critical | 0 | 0 | 0 |
| High | 3 | 0 | 3 |
| Medium | 8 | 1 (Q-11) | 9 |
| Low | 9 | 0 | 9 |
| **Total** | **20** | **1** | **21** |

Q-18 partially closed: GAP-PB-004 (CI) and GAP-PB-009 (`zig fmt --check`) addressed; coverage/fuzz/bench gaps remain.

**Top finding (PriorityScore):** Q-02 — sibling 100-175 LOC manual proto-type-matrix functions in `src/protobuf.zig` (`dupeField`, `deinitField`, `writeValue`).

The single highest-impact item by raw size and review pain remains **Q-01** (`decodeMessage`, 539 LOC, 6+ levels of nesting). Q-02 ranks fractionally higher on PriorityScore because three sibling functions multiply the ongoing maintenance cost across roughly the same surface area for a smaller refactor effort. Q-04 and Q-16 score equally high as cheap, high-frequency wins (packed-list duplication; missing `///` doc comments on the entire public `json` API).

## PriorityScore Methodology

```
PriorityScore = severity_weight × impact × (likelihood / effort)
```

- **Severity weights:** Critical=10, High=7, Medium=4, Low=1
- **impact** (1-5): how much the issue hurts maintainers/users (e.g., a 539-LOC mega-function = 5)
- **likelihood** (1-5): how often the cost manifests (daily review pain = 5; rare = 1)
- **effort** (1-5): Small=1, Medium=3, Large=5

Findings are sorted by PriorityScore descending. Cross-references to other audit docs (e.g., `GAP_ANALYSIS.md`) are noted in the final column.

## Findings (sorted by PriorityScore desc)

| ID    | Severity | PriorityScore | File:Line | Title | impact | likelihood | effort | Cross-ref |
|-------|----------|---------------|-----------|-------|--------|------------|--------|-----------|
| Q-02  | High     | 37.33         | src/protobuf.zig:635-809, :855-1027, :403-521 | `dupeField`, `deinitField`, `writeValue` — three sibling 100-175 LOC functions implement the full proto type matrix manually | 4 | 4 | 3 | — |
| Q-04  | Medium   | 36.00         | src/protobuf.zig:277-386 | Four near-identical `writePacked{Fixed,Varint,Enum,String}List` functions | 3 | 3 | 1 | — |
| Q-16  | Medium   | 36.00         | src/json.zig:5,107,117,125 | All 4 public `json` fns (`parse`, `decode`, `encode`, `stringify`) lack `///` doc comments | 3 | 3 | 1 | — |
| Q-01  | High     | 35.00         | src/wire.zig:512-1051 | `decodeMessage` is a 539-LOC mega-function with 6+ levels of nesting; mixes inline-for, ftype switch, scalar variants, oneof scaffolding | 5 | 5 | 5 | — |
| Q-03  | High     | 28.00         | bootstrapped-generator/main.zig:639-873 | `generateMessages` is 234 LOC mixing 5 concerns | 4 | 3 | 3 | — |
| Q-07  | Medium   | 24.00         | src/protobuf.zig:966-987 vs 1001-1023 | `deinitField` ArrayList free pattern duplicated; latent `unreachable` at :984 if `?ArrayListUnmanaged(primitive)` is ever generated | 3 | 2 | 1 | — |
| Q-11  | Medium   | 24.00         | tests/tests.zig:10-16, tests/alltypes.zig:12-18 | **Closed (ff50ff4)** — dead `printAllDecoded` removed from both files | 3 | 2 | 1 | GAP-PB-003 |
| Q-18  | Medium   | 21.33         | repo-wide | **Partially closed (bd2ef6a)** — CI added with fmt/build/test; coverage/fuzz/bench remain open | 4 | 4 | 3 | GAP-PB-004 closed; 009 closed; 013/014/015 still open |
| Q-05  | Medium   | 16.00         | src/protobuf.zig:456-503 | `writeValue` `repeated`/`packed_repeated` arms duplicate scalar dispatch | 2 | 2 | 1 | — |
| Q-06  | Medium   | 16.00         | src/protobuf.zig:660-693 | `dupeField` slice/optional-slice default-pointer compare logic duplicated | 2 | 2 | 1 | — |
| Q-09  | Medium   | 16.00         | src/protobuf.zig:1052-1095 | `decode_varint`, `decode_fixed` test-only helpers (dead in non-test build) | 2 | 2 | 1 | — |
| Q-10  | Medium   | 16.00         | src/protobuf.zig:1032-1041 | `ExtractedDataTag`, `ExtractedData`, `Extracted` dead types; `DecodedVarint` transitively dead | 2 | 2 | 1 | — |
| Q-08  | Medium   | 8.00          | utils/build_util.zig:20-26 | `isEnvVarTruthy` no-op stub | 1 | 2 | 1 | — |
| Q-15  | Medium   | 8.00          | src/json.zig (5), src/protobuf.zig (4), bootstrapped-generator/main.zig:1016 | 10 functions use snake_case, violating Zig naming conventions | 2 | 3 | 3 | — |
| Q-17  | Low      | 4.00          | src/protobuf.zig:8 (DecodingError), :855 (deinitField); src/wire.zig:120 (ZigZag) | Public APIs lack `///` doc comments | 2 | 2 | 1 | — |
| Q-19  | Low      | 4.00          | repo-root | Missing `CONTRIBUTING.md`, `SECURITY.md`, `CHANGELOG.md`, `.editorconfig` | 2 | 2 | 1 | — |
| Q-12  | Low      | 2.00          | build.zig:2-7, :150-153 | Six unused imports (`builtin`, `Build`, `Step`, `fs`, `mem`, `LazyPath`); redundant `addImport` | 1 | 2 | 1 | — |
| Q-21  | Low      | 2.00          | multiple files | In-tree TODOs without tracking — src/protobuf.zig:266,411,884; src/json.zig:429; tests/optionals.zig:88-90; tests/tests.zig:91; tests/tests_json.zig:1020,1024 | 2 | 2 | 2 | — |
| Q-13  | Low      | 1.00          | tests/integration.zig:2-3 | Unused `testing`, `unittest` imports; whole file is an 11-line aggregator | 1 | 1 | 1 | — |
| Q-14  | Low      | 1.00          | bootstrapped-generator/main.zig:1 | `const warn = @import("std").debug.warn` likely unused | 1 | 1 | 1 | — |
| Q-20  | Low      | 1.00          | build.zig.zon | Paths whitelist `.github` and `.devcontainer` directories that don't exist | 1 | 1 | 1 | GAP-PB-022 |

## Findings by Category

### Structural complexity (High)

- **Q-01** — `decodeMessage` mega-function (539 LOC, src/wire.zig:512-1051)
- **Q-02** — Sibling proto-type-matrix functions in src/protobuf.zig (`dupeField`, `deinitField`, `writeValue`)
- **Q-03** — `generateMessages` 234 LOC, 5 concerns (bootstrapped-generator/main.zig:639-873)

### Duplication (Medium)

- **Q-04** — Four `writePacked*List` near-identical functions (src/protobuf.zig:277-386)
- **Q-05** — `writeValue` repeated/packed_repeated scalar dispatch duplicated (src/protobuf.zig:456-503)
- **Q-06** — `dupeField` slice/optional-slice default-pointer compare logic duplicated (src/protobuf.zig:660-693)
- **Q-07** — `deinitField` ArrayList free pattern duplicated; latent `unreachable` (src/protobuf.zig:966-987 vs 1001-1023)

### Dead code

- **Q-08** — `isEnvVarTruthy` no-op stub (utils/build_util.zig:20-26)
- **Q-09** — `decode_varint`, `decode_fixed` test-only helpers (src/protobuf.zig:1052-1095)
- **Q-10** — `ExtractedDataTag`, `ExtractedData`, `Extracted`, transitively `DecodedVarint` (src/protobuf.zig:1032-1041)
- **Q-11** — `printAllDecoded` references undefined `protobuf.WireDecoderIterator` (tests/tests.zig:11)
- **Q-12** — Six unused imports + redundant `addImport` (build.zig:2-7, :150-153)
- **Q-13** — Unused `testing`, `unittest` imports in 11-line aggregator (tests/integration.zig:2-3)
- **Q-14** — `const warn = @import("std").debug.warn` likely unused (bootstrapped-generator/main.zig:1)

### Naming & docs

- **Q-15** — 10 fns use snake_case across src/json.zig, src/protobuf.zig, bootstrapped-generator/main.zig:1016
- **Q-16** — 4 public `json` fns lack `///` doc (src/json.zig:5,107,117,125)
- **Q-17** — `DecodingError`, `deinitField`, `ZigZag` lack `///` doc (src/protobuf.zig:8,:855; src/wire.zig:120)

### Tooling & meta

- **Q-18** — No CI / `zig fmt --check` / coverage / fuzz / benchmarks
- **Q-19** — Missing `CONTRIBUTING.md`, `SECURITY.md`, `CHANGELOG.md`, `.editorconfig`
- **Q-20** — `build.zig.zon` paths whitelists nonexistent `.github` / `.devcontainer`
- **Q-21** — Multiple in-tree TODOs without tracking (8 sites)

### Roadmap (effort-bucketed)

**Quick wins (< 1 day each)**

- Q-04 (consolidate `writePacked*List` via comptime dispatch)
- Q-16 (add 4 `///` doc comments to `json` public surface)
- Q-12, Q-13, Q-14 (remove unused imports)
- Q-08, Q-09, Q-10 (delete dead helpers/types)
- Q-11 (remove or fix `printAllDecoded`)
- Q-20 (drop `.github`/`.devcontainer` from `build.zig.zon` paths or create them)
- Q-19 (add stub `CONTRIBUTING.md`, `SECURITY.md`, `CHANGELOG.md`, `.editorconfig`)

**Medium (1-5 days)**

- Q-02 (extract per-type-class helpers shared by `dupeField`/`deinitField`/`writeValue`)
- Q-03 (split `generateMessages` into 5 single-concern helpers)
- Q-15 (mass-rename snake_case → camelCase across 10 sites + update callers)
- Q-18 (basic CI: `zig build`, `zig fmt --check`, `zig build test` on push/PR)
- Q-21 (open tracking issues for each TODO and link inline)

**Strategic (> 5 days)**

- Q-01 (decompose `decodeMessage` — likely needs a per-`ftype` decoder table or comptime-generated dispatch; high test surface, requires fuzz/perf coverage from Q-18 first)

## Top 5 Refactor Recommendations (sequenced)

1. **Land CI first (Q-18).** A minimal GitLab CI job running `zig build` + `zig build test` + `zig fmt --check` is a prerequisite for every other refactor — without it, structural rewrites of `decodeMessage` and the proto-type matrix have no safety net. Treat this as Step 0.

2. **Sweep dead code & unused imports (Q-08, Q-09, Q-10, Q-11, Q-12, Q-13, Q-14, Q-20).** Mechanical, low-risk, shrinks the search space for later refactors. Bundle into one MR. Q-11's broken reference also unblocks the `tests/tests.zig` test suite.

3. **Consolidate packed-list & per-type-class duplication (Q-04, Q-05, Q-06, Q-07).** Comptime dispatch over a single `writePackedList(comptime kind, ...)` (and analogous helpers for `dupeField`/`deinitField` arms) eliminates ~150 LOC and removes Q-07's latent `unreachable`. This is the highest leverage-per-effort cluster after dead-code removal.

4. **Decompose the three sibling matrices (Q-02), then `generateMessages` (Q-03).** Once Q-04/Q-05/Q-06/Q-07 have factored out the per-type-class helpers, `dupeField`, `deinitField`, and `writeValue` shrink naturally. Apply the same single-concern split to `generateMessages` so codegen and runtime evolve in lockstep.

5. **Tackle `decodeMessage` (Q-01) last.** With CI, fewer duplicated helpers, and clean per-type-class primitives, the 539-LOC monster becomes a dispatch table over `ftype` calling small, testable decoders. Pair this refactor with fuzzing (part of Q-18) since wire-format decode is the highest-risk surface in the library.

Naming (Q-15), doc comments (Q-16, Q-17), and meta files (Q-19) can be interleaved opportunistically — they touch many files but no logic, so they're best landed alongside whichever step above already opens the relevant file. Q-21 (TODO tracking) should be opened as issues in the same sprint that lands Step 1.

## Risks & Trade-offs

- **Q-01 / Q-02 carry behavioural-change risk.** The proto type matrix is implicit specification; any decomposition must keep semantics for every `ftype × cardinality × packed/optional/oneof` combination. Without Q-18's fuzz + coverage, a "pure refactor" can silently regress on wire-format edge cases. Mitigation: land Q-18 first, add property-style fuzz (round-trip encode↔decode) and a corpus from `tests/fixtures/`, then refactor.

- **Q-04's consolidation may cost binary size or inlining.** Comptime-merged `writePackedList` can defeat per-arm inlining the compiler does today. Mitigation: benchmark before/after with a `--release-fast` build (also requires Q-18 baseline). If hot, keep arms separate but extract the common epilogue.

- **Q-15 (snake_case → camelCase rename) breaks any external caller.** This is a public API of `src/protobuf.zig` and `src/json.zig`. Mitigation: introduce camelCase wrappers, deprecate snake_case names with `///deprecated` for one minor version, then remove. Document in `CHANGELOG.md` (Q-19).

- **Q-07's latent `unreachable` is a behavioural cliff.** If a future codegen change emits `?ArrayListUnmanaged(primitive)` (currently unreachable by construction), the binary will panic. Either prove the invariant in code (a comptime assert in the generator) or replace `unreachable` with the explicit free path.

- **Q-21 (TODOs) trade-off.** Inline TODOs are cheap to write and lossy to track; opening 8 issues is correct hygiene but adds GitLab maintenance overhead. If the team won't service them, deleting the TODOs (or downgrading to NOTE comments with rationale) is preferable to a stale backlog.

- **`bootstrapped-generator/` is not always built.** Several findings (Q-03, Q-14, parts of Q-15) only matter when the generator is regenerated. Confirm with maintainers whether the bootstrap path is "frozen" — if so, those findings drop in priority.

- **No coverage data exists.** Every "likelihood" rating above is a structural estimate (lines × nesting × callers). After Q-18 ships coverage, re-score and reorder this document.
