# Resolved Gaps — devnw/zig/protobuf

This file tracks gaps that were closed and what fixed them. Items here came
from `docs/GAP_ANALYSIS.md`, `docs/SECURITY_GAP_ANALYSIS.md`, and
`docs/QUALITY_GAP_ANALYSIS.md` and are mirrored back as **Closed** with
commit hashes in those source documents.

## 2026-04-26 — gap-close run (5 items)

| ID | Severity | Title | Fixed by |
|----|----------|-------|----------|
| S3 | High (Risk 140, top of security backlog) | Duplicate `errdefer` causes double-free in `repeated bytes`/`string` decode (`src/wire.zig:406-410`, CWE-415) | `b88d845 fix: close S3 - delete duplicate errdefer in decodeRepeated` — removed the second `errdefer allocator.free(bytes)` registered after `readSliceAll` (line 408). Eliminates a heap-corruption / RCE primitive reachable on `repeated bytes` / `repeated string` decode under append-OOM. |
| N1 | High (Risk 84) | `sgroup`/`egroup` path in `skipField` consumed zero bytes → CPU infinite loop on malformed unknown-field input (`src/wire.zig:1084`, CWE-835) | `92c5a59 fix: close N1 - skipField properly handles proto2 groups` — replaced the empty body with proper proto2 group skip semantics: on `sgroup`, scan inner tags until matching `egroup` at the same field number, recursively skip nested groups via `skipField` itself. Stray `egroup` returns `error.InvalidInput`. Compatible with legitimate proto2 group payloads (e.g. `unittest.proto`'s `optional_group` at field 16). |
| GAP-PB-001 | Critical (also S6 Low) | `protoc-linux-64` dependency entry pointed at `protoc-32.1-win64.zip` (`build.zig.zon:11-13`) | `b6aa932 fix: close GAP-PB-001 - remove orphan protoc-linux-64 dependency` — removed the orphan entry. The literal name `protoc-linux-64` is never constructed by `getProtocDependency` in `utils/build_util.zig` (which builds names from `protoc-{os}-{arch}`), so the entry was dormant; removing it eliminates a future foot-gun where a literal-key caller would silently fetch a Windows binary on Linux. |
| GAP-PB-003 | Critical (also Q-11) | Dead `printAllDecoded` helper referenced undefined `protobuf.WireDecoderIterator` (`tests/tests.zig:10-16`, `tests/alltypes.zig:12-18`) | `ff50ff4 chore: close GAP-PB-003 - remove dead printAllDecoded helper` — removed both copies. The function was unused by any test and would have failed to compile if invoked. |
| GAP-PB-004 | High (force-multiplier; subsumes GAP-PB-009 and partially Q-18) | No CI configuration | `bd2ef6a ci: close GAP-PB-004 - add GitLab CI pipeline` — added `.gitlab-ci.yml` with three jobs running on Zig 0.16.0: `fmt` (zig fmt --check on hand-written sources), `build` (zig build -Doptimize=Debug), `test` (zig build test --summary all). Pulls Zig 0.16.0 from ziglang.org each run. Unblocks fuzz/coverage/bench follow-ups (GAP-PB-013/014/015). |

### Verification (post-run)

- `zig build test --summary all` — 138/138 tests passed (was 138/138 pre-run; no regressions).
- `zig fmt --check` (CI invocation, applied locally) — exit 0 across all hand-written sources.
- Working tree clean apart from `docs/` updates after this run.

### Cross-domain impact

- **Security backlog reduced from 5 High → 3 High** (S1, S2a, S2b remaining).
- **Critical gaps reduced from 3 → 1** (only GAP-PB-002 sint zigzag round-trip remains).
- **Quality medium-priority Q-11 closed**; Q-18 partially closed (CI/fmt-check landed; coverage/fuzz/bench still open).
