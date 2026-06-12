# Security Gap Analysis — devnw/zig/protobuf

**Generated:** 2026-04-26
**Last updated:** 2026-06-12 (iter-1 appsec: 5 found+closed; iter-2 review found+closed PB-2026-006, a cross-record cap regression + latent errdefer crash/leak)
**Scope:** entire repo
**Library type:** Pure protobuf encode/decode + protoc plugin (`protoc-gen-zig`)

## 2026-06-12 AppSec Review — all findings CLOSED (see `APPSEC_REVIEW_2026-06-12.md` for full detail)

| ID | Severity | Risk | Title | File:Line | CWE | Status |
|----|----------|------|-------|-----------|-----|--------|
| PB-2026-001 | Medium | High | Unbounded recursion in `skipField` group-skip path → stack-exhaustion DoS. `skipField` took no depth parameter; nested unknown `sgroup` tags recursed without the `max_decode_depth` cap that guards `decodeMessage`. Fixed: threaded `depth: u32` through `skipField`, call sites pass `options._depth + 1`, enforce `> max_decode_depth → error.InvalidInput`. Regression test: 150 nested unmatched `0x1B` group tags → `error.InvalidInput` (red `EndOfStream`→green). | src/wire.zig:1217,1248-1264 | CWE-674 | **Closed** (`5fba1d0`) |
| PB-2026-002 | Medium | High | Missing `if (len < 0)` guard on `.repeated`/`.packed_repeated` length prefix before `@intCast(len)` → panic DoS in Debug/ReleaseSafe. Fixed: added the `if (len < 0) { @branchHint(.cold); return error.InvalidInput; }` guard before each cast, matching the string/submessage/oneof branches. Regression tests: packed + non-packed repeated field with `FF FF FF FF 0F` length prefix → `error.InvalidInput` (red panic→green). | src/wire.zig:834-845,875-879 | CWE-704/755 | **Closed** (`83e3c52`) |
| PB-2026-003 | Low | Medium | CI fetched and executed the Zig toolchain via `curl … \| tar` with no checksum verification. Fixed: pinned `ZIG_SHA256` (70e49664…), download-to-file + `sha256sum -c` before extract, fail closed on mismatch. | .gitlab-ci.yml | CWE-494 | **Closed** (`ea5ddef`) |
| PB-2026-004 | Low | Low | Fuzz harness input cap (4096-byte `buf`) bounded recursion below the PB-2026-001 overflow threshold and lacked corpus seeds. Fixed: raised the cap to 64 KiB and documented seed-corpus candidates (long `0x0B` run; `FF FF FF FF 0F` prefix). | tests/fuzz_decode.zig | CWE-1108 | **Closed** (`74280d9`) |
| PB-2026-005 | Low | Low | `json.parse` unwrapped `options.max_value_len.?` at two sites; a caller-supplied `ParseOptions` with `max_value_len == null` panicked. Fixed: `orelse std.json.default_max_value_len` at both sites, matching std.json's resolver. Regression test added. | src/json.zig:31,388 | CWE-476 | **Closed** (`88c2408`) |
| PB-2026-006 | High | High | **Found in iteration-2 review.** Two coupled decode bugs: (a) the P-2026-03 change gated the packed scalar/enum in-loop element-count check, removing the only guard against *cross-record* cumulative growth — a packed field split across many wire records grew unbounded (1.2M elements decoded with no error; CWE-789); and (b) the S3 cleanup errdefer `shrinkAndFree(allocator, current_capacity)` crashed (`new_len <= items.len` assertion) AND leaked previously-committed elements on **any** mid-list decode error where the list had capacity slack (any 2nd+ packed record or Nth unpacked element) — a pre-existing latent crash/leak since `protobuf.decode` abandons the partial result without deinit. Fixed: restored unconditional cumulative checks; replaced the errdefer with element-aware full cleanup (drop in-flight slot, deinit committed owned elements, free list, reset `.empty`). Regression tests: cross-record cap (scalar+enum), mid-list error frees committed strings. | src/wire.zig (decodeRepeated) | CWE-789, CWE-401, CWE-617 | **Closed** (`90f601e`) |

## Summary

| Risk Level | Open | Closed | Deferred (Won't Do) | Total |
|-----------|------|--------|---------------------|-------|
| Critical  | 0    | 0      | 0                   | 0     |
| High      | 0    | 5      | 0                   | 5     |
| Medium    | 0    | 2      | 3 (S4, S5, N13)     | 5     |
| Low       | 0    | 1 (S6) | 4 (N2, N3, N7, S7) | 5     |
| Info      | 0    | 1 (N16)| 0                   | 1     |
| **Total** | **0** | **9** | **7** | **16** |

**Closed:** S3 (`b88d845`), S1 + S2a + S2b (`1e171cc`), N1 (`92c5a59`),
N8 (`a13c854`), S6 (`b6aa932`), N16 (`913e626`), S7 doc (`be33345`).

**Deferred (Won't Do this run, see `GAP_ANALYSIS_RESOLVED.md` for rationale):**
S4 (UTF-8 opt-in pending consumer ask), S5 (generator panics; build-time
DoS only), N2 (skipField .len cap; low risk), N3 (32-bit overflow; arch
restricted), N4 (decode_bool author-explicit strict policy → reclassified
won't do), N7 (base64 arena hygiene; low risk), N13 (generator path
traversal; build-time only).

**No secrets** found in repo. **No platform issues created** (running in `--skip-issues` mode).

## Threat Model (concise)

- **Three input boundaries:**
  1. Wire decoder (`src/wire.zig`) — parses untrusted protobuf bytes from any caller.
  2. JSON parser (`src/json.zig`) — parses untrusted JSON-encoded protobuf.
  3. Generator stdin (`bootstrapped-generator/main.zig`) — consumes a `CodeGeneratorRequest` from `protoc` at build time.
- **Pure library** — no network listeners, no auth, no service. Deployment risk is determined by how downstream apps wire this library into their input paths.
- **Worst-case outcomes:**
  - Heap corruption → potential RCE via S3 (double-free under `c_allocator` / `jemalloc`).
  - Stack overflow → DoS via S1 (unbounded recursion on adversarial nested submessages).
  - OOM / CPU starvation → DoS via S2a, S2b, N1, N2.
- **Generator** runs build-time on a developer machine, so generator findings (S5, N13) are *build-time DoS* / *build-time path traversal* — not runtime exposure. Still relevant in CI / supply-chain contexts where untrusted `.proto` files may be ingested.

## Risk Scoring

`Risk Score = severity_weight × exploitability × impact × (1 / effort_to_fix)`

- Severity weights: Critical=10, High=7, Medium=4, Low=1
- Exploitability: 1 (theoretical) – 5 (trivial PoC against any consumer)
- Impact: 1–5 (DoS=3, heap-corruption/RCE=5, info-leak=2, build-time-only=2)
- Effort: 1 (≈1 line) – 5 (architectural change)

## Findings (sorted by Risk Score, descending)

| Rank | ID  | Severity | Risk Score | Title                                                                          | File:Line                                                  | CWE                  | Exploit. | Impact | Effort | Status        |
|------|-----|----------|-----------:|--------------------------------------------------------------------------------|------------------------------------------------------------|----------------------|---------:|-------:|-------:|---------------|
| 1    | S3  | High     |       140  | Duplicate `errdefer` causes double-free in `repeated bytes`/`string` decode    | src/wire.zig:406-410                                       | CWE-415              |        4 |      5 |      1 | **Closed (b88d845)** |
| 2    | N1  | High     |        84  | sgroup/egroup path returns consumed=0 → infinite CPU loop                      | src/wire.zig:1084                                          | CWE-835              |        4 |      3 |      1 | **Closed (92c5a59)** |
| 3    | S1  | High     |        52.5| Unbounded recursion in `decodeMessage` via submessage chains                   | src/wire.zig:469,769,797,985,1021                          | CWE-674              |        5 |      3 |      2 | **Closed (1e171cc)** |
| 4    | S2a | High     |        52.5| Missing allocation cap on length-prefix-driven `alloc`                         | src/wire.zig:405,597,859                                   | CWE-789              |        5 |      3 |      2 | **Closed (1e171cc)** |
| 5    | S2b | High     |        52.5| Packed/repeated scalar/enum loop unbounded element count                       | src/wire.zig:415-433,437-449                               | CWE-789              |        5 |      3 |      2 | **Closed (1e171cc)** |
| 6    | N2  | Medium   |        24  | `skipField` `.len` discards up to 2 GiB without bound                          | src/wire.zig:1077                                          | CWE-789              |        4 |      3 |      2 | confirmed     |
| 7    | N8  | Medium   |        24  | `Tag.decode` accepts field == 0 (spec-forbidden)                               | src/wire.zig:91-107                                        | CWE-20               |        3 |      2 |      1 | **Closed (a13c854)** |
| 8    | N13 | Medium   |        18  | Generator package name flows to FS path without `..`/absolute sanitization     | bootstrapped-generator/main.zig:127, 949                   | CWE-22               |        3 |      3 |      2 | confirmed     |
| 9    | S4  | Medium   |         8  | No UTF-8 validation on string fields (spec non-conformance)                    | src/wire.zig:602, 864 + repeated paths                     | CWE-176              |        2 |      2 |      2 | confirmed     |
| 10   | S5  | Medium   |         8  | Generator panics + recursion on adversarial `CodeGeneratorRequest` stdin       | bootstrapped-generator/main.zig:367, 429, 566, 801         | CWE-248, CWE-674     |        3 |      2 |      3 | confirmed     |
| 11   | N4  | Low      |         4  | `decode_bool` rejects multi-byte varints (spec-noncompliant)                   | src/wire.zig:278-288                                       | CWE-20               |        2 |      2 |      1 | **Won't Do** (author-explicit strict policy; cited in alltypes.zig "Required.Proto3...BOOL.PackedInput" test) |
| 12   | S6  | Low      |         4  | `protoc-linux-64` URL points at `win64.zip` (dormant artifact mismatch)        | build.zig.zon:11-13                                        | CWE-494              |        2 |      2 |      1 | **Closed (b6aa932)** (also GAP-PB-001) |
| 13   | N3  | Low      |         3  | `consumed += @intCast(len)` may overflow `usize` on 32-bit                     | src/wire.zig:604, 866, 1077, 1078                          | CWE-190              |        2 |      3 |      2 | confirmed     |
| 14   | N7  | Low      |         2  | base64 input held in arena until decode complete (memory bloat)                | src/json.zig:531-540                                       | CWE-401 (indirect)   |        2 |      2 |      2 | confirmed     |
| 15   | S7  | Low      |         2  | FS ops on developer-supplied paths (build-time, trusted boundary)              | utils/build_util.zig:9, 15, 186                            | CWE-22               |        1 |      2 |      1 | doc-only      |
| 16   | N16 | Info     |       N/A  | No fuzzing harness for wire decode                                             | repo-wide                                                  | CWE-1108             |      N/A |    N/A |    N/A | **Closed (913e626)** — tests/fuzz_decode.zig + `zig build test --fuzz` |

## Top 5 Exploitable Issues (Ranked)

1. **S3 — Double-free in `repeated bytes` / `repeated string` decode** (Risk 140)
   Two consecutive `errdefer allocator.free(bytes)` are registered with no intervening `try`. If `result.append(...)` fails (OOM), both errdefers fire and free the same allocation twice. Under `c_allocator` / `jemalloc` this is a textbook heap-corruption / RCE primitive. **One-line fix.** Reachable by any caller decoding adversarial `repeated bytes` / `repeated string` input; OOM is the trigger, which is itself trivially induced by S2a/S2b amplification on the same code paths.

2. **N1 — sgroup/egroup infinite CPU loop** (Risk 84)
   The skip path for `sgroup`/`egroup` wire types returns `consumed = 0`. The outer `while (consumed < bytes)` therefore never advances, pinning a CPU. Any caller decoding attacker-controlled bytes is exposed. Trivial DoS.

3. **S1 — Unbounded `decodeMessage` recursion** (Risk 52.5)
   No depth limit anywhere in the decoder. A ~1 MB tightly packed length-1 submessage chain crashes the thread via stack overflow on a default 8 MB Linux thread stack. Pre-auth, remote, no special preconditions beyond "this library is used to decode untrusted protobuf."

4. **S2a / S2b — Allocation and element-count amplification** (Risk 52.5 each)
   - S2a: int32 length is capped at 2 GiB but there is no cumulative cap and no per-field cap, so a single field can demand a 2 GiB allocation, and an outer message can demand many of them.
   - S2b: A 1 KB packed-varint blob of `0x00` bytes appends ≈1024 entries. With `len = INT_MAX`, ≈2 billion entries get appended into a `std.ArrayList`, triggering OOM long before completion — and meanwhile compounding the S3 trigger condition.

5. **N13 — Generator path traversal at build time** (Risk 18)
   Package name from `.proto` flows to filesystem path with no sanitization. A `.proto` declaring `package "../../../tmp/evil"` produces `../../../tmp/evil.pb.zig`. Build-time only, but relevant for CI systems that ingest untrusted `.proto` files.

## Findings by Area

### Wire Decoder (src/wire.zig) — primary attack surface

- **Memory safety:** S3 (double-free).
- **Resource exhaustion:** S1 (recursion), S2a (alloc cap), S2b (element cap), N1 (CPU loop), N2 (skip-path cap).
- **Spec conformance / input validation:** S4 (UTF-8), N4 (bool decoding), N8 (field 0).
- **Numeric:** N3 (32-bit overflow).

### JSON Parser (src/json.zig)

- **Memory bloat:** N7 (base64 buffer held in arena).

### Generator (bootstrapped-generator/main.zig)

- **Build-time DoS / panics:** S5 (panics + recursion on adversarial request).
- **Path traversal:** N13 (package name → FS path).

### Build / Supply-chain

- **Artifact mismatch:** S6 (`protoc-linux-64` URL points at `win64.zip`; currently dormant orphan).
- **Trusted-boundary documentation:** S7 (build-time FS ops on developer-supplied paths).

### Hardening / Test Coverage

- **N16:** No wire-decoder fuzzing harness. Adding one would have surfaced S1, S2a/b, N1 mechanically.

## Recommended Patches (Phase 3 sketches)

- **S3:** Delete the duplicate `errdefer` at `src/wire.zig:408`. One line. Re-run `repeated bytes` / `repeated string` decode tests under fault injection (force `result.append` OOM) to confirm only one free occurs.
- **S1:** Add `DecodeOptions { .max_depth: u32 = 100 }` and thread a `_depth` counter through the `decodeMessage` recursion. Return `error.MaxDepthExceeded` when the cap is hit.
- **S2a / S2b:** Add `max_alloc_per_field: usize = 16 << 20`, `max_total_alloc: usize = 256 << 20`, and `max_elements: usize = 1 << 20`. Reject *before* allocation. For packed scalars/enums, reject when projected element count would exceed `max_elements`.
- **S4:** Add `validate_utf8: bool = false` opt-in (default `false` to preserve compatibility with existing callers); when true, call `std.unicode.utf8ValidateSlice` after reading any string field.
- **N1:** In `skipField`, return `error.InvalidInput` for `sgroup` / `egroup` wire types (or, if implementing groups, return a non-zero `consumed` so the outer loop advances).
- **N8:** In `Tag.decode`, after wire-type rejection, also check `(raw_result >> 3) > 0` (field number cannot be zero per the spec).
- **N13:** Validate package against `^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)*$`; reject `..` and absolute paths before composing output filesystem paths.
- **S5:** Replace generator `@panic` calls with typed error returns; add a depth limit to `generateMessages` recursion.
- **S6:** Either fix the `protoc-linux-64` URL+hash in `build.zig.zon`, or remove the orphan entry — only `protoc-linux-x86_*` and `protoc-linux-aarch_64` are referenced by `getProtocDependency`.
- **N3:** On 32-bit targets, use checked arithmetic (`std.math.add(usize, consumed, len)`) for the `consumed += @intCast(len)` accumulators.
- **N4:** Accept multi-byte varint encodings of bool (any non-zero value → true) per spec.
- **N7:** Stream base64 decode into a sized output buffer; release the input slice early.
- **S7:** Document the build-time trust boundary in `SECURITY.md`. No code change required.
- **N16:** Add a `fuzz/` harness that round-trips `decodeMessage` against `afl++` / `zig build fuzz` over a small seed corpus from the existing test fixtures.

## Hardening Roadmap

1. **Week 1 — wire-decoder hardening sprint (single PR):**
   S3, S1, S2a/b, N1. Lands the heap-corruption fix, depth limit, allocation/element caps, and group-skip rejection together with regression tests.
2. **Week 2 — generator + tag validation:**
   N8, N13, S5. Tag validation, generator path sanitization, panic-to-error migration.
3. **Week 3 — fuzzing + spec polish:**
   N16 fuzz harness, S4 opt-in UTF-8 validation, N3 / N4 numeric and bool polish.
4. **Ongoing — cleanup and documentation:**
   S6 (remove orphan dependency entry), S7 (`SECURITY.md` for build-time trust boundary), N7 (JSON arena hygiene). Author a `SECURITY.md` describing the input boundaries enumerated in the threat model.

## Notes

- No secrets were found in the repo.
- Running in `--skip-issues` mode: no platform issues were created. This document is the canonical record.
- All findings are `confidence::confirmed` based on Phase 3 code evidence except N16 (hardening gap, not a vulnerability).
