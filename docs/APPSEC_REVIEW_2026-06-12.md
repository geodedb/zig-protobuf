# AppSec Review — zig-protobuf — 2026-06-12

## 1. Scope & Assumptions

**Target:** `/data/home/benji/src/gl/gitlab.com/devnw/zig/protobuf` — a pure-Zig Protocol Buffers library (Zig 0.15.1 / toolchain 0.16.0 in CI) plus a build-time `protoc` plugin code generator. Distributed as source via git tags; consumers compile it themselves.

**Reviewed (read in full):**
- Wire codec: `src/wire.zig` (decode/encode, the primary untrusted-input surface), `src/protobuf.zig` (message encode/decode/dupe/deinit), `src/json.zig` (JSON parse/stringify over `std.json`).
- Observability seam: `src/observability.zig`, `src/observability_init.zig`.
- Build-time codegen: `bootstrapped-generator/main.zig`, `bootstrapped-generator/FullName.zig`.
- Build / supply chain: `build.zig`, `utils/build_util.zig`, `build.zig.zon`, `.gitlab-ci.yml`, `.pre-commit-config.yaml`, `scripts/detect_diamond_deps.py`, `scripts/compare.py`, `scripts/ab_runner.sh`, `scripts/host_state.sh`, `scripts/stress_followup.sh`.
- Regression coverage: `tests/tests.zig` hardening block, `tests/fuzz_decode.zig`, test inventory.
- Git history since 2026-04-26 (commits `ad5200f`..`b842402`).

**Threat model (inferred):** The only attacker-controlled data crossing a trust boundary at runtime is **the byte stream passed to `decode()` / JSON `parse()`**. A consumer embeds this library to parse protobuf/JSON from untrusted peers (network, files, IPC). The relevant abuse goal is therefore decoder denial-of-service or memory-safety violation on crafted input. The build-time generator's trust boundary is the developer's `.proto`/descriptor set (build-time, developer-controlled). CI/supply-chain integrity protects the release pipeline.

**Assumptions:** Reviewed source only; did not build, run tests, fuzz, or execute scripts (read-only). Memory-safety reasoning assumes Zig semantics where `@intCast` of an out-of-range value is checked illegal behavior (panic) in Debug/ReleaseSafe and UB in ReleaseFast/ReleaseSmall. The default `zig build` and the project's CI both use **Debug**; production consumers commonly use **ReleaseSafe**.

---

## 2. Executive Summary

- **Two decoder DoS gaps on untrusted input remain open**, both in `src/wire.zig`, both *uncovered by the existing hardening tests and fuzz harness*. They are the natural "next layer" beyond the closures that were already verified.
  - **PB-2026-001 (Medium):** the proto2 **group-skip path (`skipField`) recurses without any depth cap**. The `max_decode_depth` guard added to `decodeMessage` does *not* cover `skipField`, so nested unknown-group tags drive unbounded recursion → stack-exhaustion crash. The prior "N1" fix removed the *infinite loop* but left *uncontrolled recursion* (CWE-674).
  - **PB-2026-002 (Medium):** the `.repeated` and `.packed_repeated` branches cast a length prefix to `usize` **without the `if (len < 0)` guard** that the string/submessage/oneof branches all have. A length-prefix that decodes to a negative `int32` reaches `@intCast(len)` → panic/abort in Debug/ReleaseSafe.
- **One supply-chain integrity gap (Low):** CI downloads and executes the Zig toolchain via `curl … | tar` with **no checksum/signature verification** (`.gitlab-ci.yml:10`). Blast radius is limited to the self-hosted runner because the package ships as source.
- **The previously-closed hardenings verified as still holding:** recursion depth cap for nested *submessages* (`decodeMessage`), per-field allocation cap (16 MiB), element-count cap (1M), the repeated-bytes/string double-free fix ("S3"), and the group infinite-loop fix ("N1") for the *loop-termination* property. See §5.
- **No findings** in the JSON layer, the observability seam (hard-disabled, no telemetry/secret egress), the code generator, the Python/shell tooling (stdlib-only, no shell/eval, operate on developer/CI-controlled inputs and are not shipped to consumers), or the dependency manifest (protoc binaries are pinned by URL **and** content hash).
- **Overall confidence: High** for the two decoder findings (concrete code paths, confirmed reachability, confirmed absence of test coverage). The library's security posture is otherwise strong and clearly hardening-conscious.

---

## 3. Findings Table

| ID | Severity | Confidence | Title | Location | CWE | OWASP 2025 | Status |
|----|----------|-----------|-------|----------|-----|-----------|--------|
| PB-2026-001 | Medium | High | Unbounded recursion in group-skip path → stack-exhaustion DoS | `src/wire.zig:1217,1248-1264` (call `:1262`) | CWE-674 (also CWE-400) | A10 Mishandling of Exceptional Conditions | Open |
| PB-2026-002 | Medium | High | Missing negative-length guard on repeated/packed length prefix → panic DoS | `src/wire.zig:834-845`, `:875-879` | CWE-704 / CWE-755 (also CWE-20) | A10 Mishandling of Exceptional Conditions | Open |
| PB-2026-003 | Low | High | CI fetches & runs Zig toolchain without integrity verification | `.gitlab-ci.yml:10` | CWE-494 | A08 Software or Data Integrity Failures | Open |

---

## 4. Finding Details

### PB-2026-001 — Unbounded recursion in `skipField` group skipping → stack-exhaustion DoS

**Severity:** Medium · **Confidence:** High · **OWASP:** A10 (Mishandling of Exceptional Conditions) · **CWE:** CWE-674 Uncontrolled Recursion (with CWE-400 Uncontrolled Resource Consumption)

**Evidence.** The submessage recursion limit lives only in `decodeMessage`:

`src/wire.zig:671-675`
```zig
) DecodeError!usize {
    if (options._depth > max_decode_depth) {
        @branchHint(.cold);
        return error.InvalidInput;
    }
```

But unknown fields with a *group* wire type are dispatched to `skipField`, which takes **no depth parameter** and recurses on itself for nested groups:

`src/wire.zig:1217` and `:1248-1264`
```zig
fn skipField(reader: anytype, tag: Tag) DecodeError!usize {   // <-- no _depth
    ...
        .sgroup => {
            // proto2 group: scan inner tags until the matching egroup.
            while (true) {
                const inner, const c = try Tag.decode(reader);
                consumed += c;
                if (inner.wire_type == .egroup) { ... break; }
                consumed += try skipField(reader, inner);   // :1262  <-- unbounded recursion
            }
        },
```

`Tag.decode` accepts wire types 0–5, including `sgroup = 3` (`src/wire.zig:59-72`, `:136-140`), so a tag whose field number is not in the descriptor and whose wire type is `sgroup` lands here. Each nested `sgroup` tag (one byte for a small field number, e.g. `0x0B` = field 1 / wire 3) adds one `skipField` stack frame with no limit.

**Source-to-sink trace.** Public entry `protobuf.decode` calls `decodeMessage` with **no `bytes` cap** (streaming):

`src/protobuf.zig:1211-1219`
```zig
pub fn decode(comptime T: type, reader: anytype, allocator: std.mem.Allocator) !T {
    var result: T = undefined;
    internal_init(T, &result);
    _ = try wire.decodeMessage(&result, allocator, reader, .{});   // options.bytes == null
```
→ `decodeMessage` main loop reads a tag; an unknown `sgroup` field falls through to `else consumed += try skipField(reader, tag);` (`src/wire.zig:1212`) → `skipField` `.sgroup` branch → recursion at `:1262`. Attacker bytes → `reader` → recursion depth. No `_depth` is threaded in, so `max_decode_depth` never applies.

**Attack scenario (non-destructive).** A peer sends a message body consisting of repeated single-byte group-start tags for an unknown field, e.g. N copies of `0x0B` followed by EOF. `skipField` recurses N times before any `egroup` or `EndOfStream` unwinds it. With small per-frame size, on the order of ~10^5 nested tags (~80–100 KB of input on a typical 8 MiB stack) exhausts the stack and aborts the process. Because the top-level decode imposes no byte ceiling, the input size is bounded only by what the consumer is willing to read.

**Why existing controls fail.** `max_decode_depth` is enforced in `decodeMessage` only. Groups never go through `decodeMessage`; they are skipped inline in `skipField`, which has no depth state. The per-field alloc cap and element cap are irrelevant (no allocation occurs on this path). The "N1" fix made each iteration consume ≥1 byte (terminating the *loop*), but recursion still grows the *stack* unboundedly.

**Coverage gap.** No test exercises wire-level `sgroup`/`egroup` skipping (`tests/tests.zig` hardening block covers submessage depth, dupe depth, and huge string length only; the `group` hits in `tests/protos_for_test/*.proto` are commented-out proto2 group declarations, not decoder tests). `tests/fuzz_decode.zig` caps fuzzer input at 4096 bytes (`buf: [4096]u8`), which bounds recursion to ~4096 frames — likely below the overflow threshold — so the fuzzer is unlikely to surface this.

**Impact.** Remote/untrusted-input denial of service (process crash) for any consumer that decodes attacker-influenced bytes via `decode()`.

**Root cause.** Depth accounting is attached to `decodeMessage` but the group-skip recursion is a second, independent recursion site that was not given the same guard.

**Remediation.** Thread a depth counter through `skipField` and enforce `max_decode_depth`, mirroring `decodeMessage`:
```zig
fn skipField(reader: anytype, tag: Tag, depth: u32) DecodeError!usize {
    if (depth > max_decode_depth) {
        @branchHint(.cold);
        return error.InvalidInput;
    }
    ...
        .sgroup => {
            while (true) {
                const inner, const c = try Tag.decode(reader);
                consumed += c;
                if (inner.wire_type == .egroup) { ... break; }
                consumed += try skipField(reader, inner, depth + 1);
            }
        },
```
Update both call sites (`src/wire.zig:1208`, `:1212`) to pass `options._depth + 1` (groups are a nesting level, so they should share the message-depth budget). An equivalent non-recursive fix is to convert group skipping to an explicit depth counter/stack and cap it.

**Regression tests.** Add a hardening test that encodes ~`max_decode_depth + 1` nested unknown `sgroup` tags (e.g. repeated `0x0B`) and asserts `error.InvalidInput` rather than a crash; and a "balanced deep group then `egroup`" variant to confirm well-formed-but-deep groups are also rejected at the cap. Consider raising the `fuzz_decode` buffer or seeding a corpus entry with a long `0x0B` run.

**References / mappings.** OWASP A10; CWE-674; CIS Controls v8.1.2 16.1 (secure application development), 16.11 (vetted handling of untrusted input). Mirrors the already-closed CWE-674 mitigation in `decodeMessage`.

---

### PB-2026-002 — Missing negative-length guard on `repeated` / `packed_repeated` length prefix → panic DoS

**Severity:** Medium · **Confidence:** High · **OWASP:** A10 (Mishandling of Exceptional Conditions) · **CWE:** CWE-704 Incorrect Type Conversion / CWE-755 Improper Handling of Exceptional Conditions (with CWE-20)

**Evidence.** Length prefixes are decoded as **signed `int32`** and can legitimately be negative. The string, submessage, and oneof branches all reject a negative length before casting; the two repeated branches do not.

Guarded sites (correct):
- `src/wire.zig:747` (scalar string/bytes): `if (len < 0) { ... return error.InvalidInput; }`
- `src/wire.zig:893` (submessage): `if (len < 0) { ... return error.InvalidInput; }`
- `src/wire.zig:1013` and `:1082` (oneof string / oneof submessage): same guard.

Unguarded sites (the finding):

`src/wire.zig:833-846` — `.packed_repeated`, packed encoding:
```zig
if (tag.wire_type == .len) {
    const len, const c = try decodeScalar(.int32, reader);   // len: i32, may be negative
    consumed += c;
    consumed += try decodeRepeated(
        ...,
        .{ .bytes = @intCast(len), ._depth = options._depth },  // :845  no `len < 0` check
    );
}
```

`src/wire.zig:875-885` — `.repeated`:
```zig
const len: ?usize = if (tag.wire_type == .len) b: {
    const len, const c = try decodeScalar(.int32, reader);
    consumed += c;
    break :b @intCast(len);   // :878  no `len < 0` check
} else null;
```

**Reachability is proven by the decoder's own unit test.** `decodeScalar(.int32, …)` returns `-1` for the five-byte input `FF FF FF FF 0F` (`src/wire.zig:442-455`, "Valid `int32` encoded as `int32`"). So an attacker who sets a repeated/packed field's length prefix to that byte sequence yields `len == -1`, and `@intCast(-1)` to `usize` is reached.

**Source-to-sink trace.** Attacker bytes → `reader` → `decodeMessage` matches a `.repeated`/`.packed_repeated` field (`src/wire.zig:818`, `:862`) with `tag.wire_type == .len` → `decodeScalar(.int32)` returns negative → `@intCast(len)` (`:845` / `:878`). In Debug/ReleaseSafe this is checked illegal behavior → **panic/abort**. In ReleaseFast/ReleaseSmall it is UB that produces a very large `usize`, which the downstream `expected_count > max_decode_elements` / `bytes > max_decode_elements` checks in `decodeRepeated` (`src/wire.zig:523`, `:565`) then convert to `error.InvalidInput` — i.e. the crash is masked only in unsafe build modes.

**Attack scenario (non-destructive).** A peer encodes a packed `repeated` field (e.g. `repeated int32 ... [packed=true]`) with the tag for that field followed by the length-prefix bytes `FF FF FF FF 0F`. A consumer built in Debug (the project's own CI default: `zig build -Doptimize=Debug`, `.gitlab-ci.yml:47`) or ReleaseSafe aborts on decode.

**Why existing controls fail.** The negative-length guard pattern exists elsewhere in the same function but was omitted on these two branches. The element/alloc caps run *after* the cast, so they cannot prevent the cast panic in safe modes.

**Impact.** Untrusted-input denial of service (process abort) in Debug/ReleaseSafe builds — the modes Zig recommends for production and that this project uses in CI.

**Root cause.** Inconsistent application of the `if (len < 0) return error.InvalidInput;` precondition across the length-prefixed branches; `int32` (signed) is used for an inherently unsigned length.

**Remediation.** Add the same guard before each cast:
```zig
// .packed_repeated, src/wire.zig:834
const len, const c = try decodeScalar(.int32, reader);
consumed += c;
if (len < 0) { @branchHint(.cold); return error.InvalidInput; }
... .bytes = @intCast(len) ...

// .repeated, src/wire.zig:876
const len, const c = try decodeScalar(.int32, reader);
consumed += c;
if (len < 0) { @branchHint(.cold); return error.InvalidInput; }
break :b @intCast(len);
```
(Longer term, consider decoding length prefixes as unsigned, e.g. `uint32`, and range-checking against `max_decode_alloc_per_field` consistently, as the string branch already does at `:751`.)

**Regression tests.** Add decode tests for both a packed and a non-packed `repeated` field whose length prefix is `FF FF FF FF 0F` (and a 10-byte over-long form), asserting `error.InvalidInput` rather than panic; run them under Debug (and ReleaseSafe if the suite supports mode matrices).

**References / mappings.** OWASP A10; CWE-704, CWE-755, CWE-20; CIS Controls v8.1.2 16.1/16.11. Closes the asymmetry with the already-guarded sites at `:747`, `:893`, `:1013`, `:1082`.

---

### PB-2026-003 — CI fetches and executes the Zig toolchain without integrity verification

**Severity:** Low · **Confidence:** High · **OWASP:** A08 (Software or Data Integrity Failures) · **CWE:** CWE-494 Download of Code Without Integrity Check

**Evidence.** `.gitlab-ci.yml:7-12`
```yaml
before_script:
  - apt-get update -qq
  - apt-get install -y --no-install-recommends curl ca-certificates xz-utils
  - curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" | tar -xJf -
  - export PATH="$CI_PROJECT_DIR/zig-x86_64-linux-${ZIG_VERSION}:$PATH"
  - zig version
```
The compiler tarball is fetched over HTTPS and piped straight into `tar` and then onto `PATH` and executed. There is no SHA-256 comparison and no minisign signature check, even though ziglang.org publishes both. (By contrast, the `apt-get` packages are integrity-verified by APT's signed repositories, and `build.zig.zon` pins every `protoc` binary by content hash — so this is the one unverified executable in the pipeline.)

**Attack scenario.** Compromise of the ziglang.org origin/CDN, a malicious cache/mirror, or TLS/DNS subversion of the runner would deliver a backdoored `zig` that then runs `zig build` / `zig build test` on a self-hosted runner (`tags: [company, linux]`) with access to the checked-out repo and the runner environment. Because the runner participates in release tagging, a tainted toolchain could in principle influence tagged artifacts or exfiltrate any runner-resident secrets.

**Impact / blast radius (mitigated).** HTTPS provides transport integrity (not origin integrity). Critically, this package is distributed to consumers **as source** (git tags) and they compile with their *own* Zig, so a compromised CI compiler does not directly taint what downstream consumers fetch. The practical exposure is the CI runner itself and any credentials it holds. Hence Low, rising to Medium if the runner stores publish/registry credentials.

**Root cause.** Convenience toolchain bootstrap without a pinned digest.

**Remediation.** Pin and verify before use:
```yaml
variables:
  ZIG_VERSION: "0.16.0"
  ZIG_SHA256: "<known-good-sha256>"
before_script:
  - apt-get update -qq && apt-get install -y --no-install-recommends curl ca-certificates xz-utils minisign
  - curl -fsSLO "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz"
  - echo "${ZIG_SHA256}  zig-x86_64-linux-${ZIG_VERSION}.tar.xz" | sha256sum -c -
  # optional, stronger: verify the minisign signature against Zig's published public key
  - tar -xJf "zig-x86_64-linux-${ZIG_VERSION}.tar.xz"
```
Prefer minisign verification against Zig's published key for origin authenticity, and keep `ZIG_SHA256` updated when bumping the version.

**Verification.** Confirm the job fails closed when the digest is altered (negative test in a scratch pipeline).

**References / mappings.** OWASP A08; CWE-494; CIS Controls v8.1.2 2.x (authorized software), 7.x (integrity/patch), 16.x (secure development pipeline).

---

## 5. Secure Design Notes (positive controls observed)

- **Decoder hardening is deliberate and largely sound.** Constants `max_decode_depth = 100`, `max_decode_alloc_per_field = 16 MiB`, `max_decode_elements = 1_000_000` (`src/wire.zig:44-56`) are enforced consistently for submessages, strings, and repeated/packed element counts (`:493`, `:503`, `:523`, `:551`, `:565`, `:609`, `:751`, `:1017`). Allocation caps are checked **before** allocating.
- **Prior closure verified — submessage recursion (CWE-674):** the `_depth` counter is threaded through `decodeMessage` ↔ `decodeRepeated` ↔ submessage/oneof recursion and capped (`:619`, `:672`, `:933`, `:961`, `:1156`, `:1192`); pinned by `tests/tests.zig:83` ("max_decode_depth rejects deeply-nested submessages", depth 200 → `InvalidInput`). Holds. (PB-2026-001 is the *separate* group-skip recursion site that this guard does not reach.)
- **Prior closure verified — repeated bytes/string double-free ("S3"):** `decodeRepeated` uses `errdefer result.shrinkRetainingCapacity(current_items)` plus `errdefer result.shrinkAndFree(...)` (`:482-485`) so that an element appended just before a cap-triggered `error.InvalidInput` (`:502-506`) is dropped from the list, while the buffer is freed exactly once by its local `errdefer allocator.free(bytes)` (`:499`). The single-string replace path also frees the prior value only when it differs from the type default and after the new buffer is allocated (`:768-797`). No double-free path found.
- **Prior closure verified — group infinite loop ("N1", CWE-835):** `skipField`'s `.sgroup` branch now consumes ≥1 byte per iteration and terminates on the matching `egroup` or propagates `EndOfStream` (`src/wire.zig:1248-1264`); a stray `egroup` is rejected (`:1265-1269`). The loop-termination property holds (the residual issue is recursion depth, PB-2026-001).
- **`dupe` is depth-capped** (`max_dupe_depth = 100`, `src/protobuf.zig:762-779`) guarding against self-referential message graphs; pinned by `tests/tests.zig:123`.
- **Tag validation:** `Tag.decode` rejects wire types > 5 and field number 0 (`src/wire.zig:136-148`); `int32` over-range and over-long varints are rejected (`:327-339`, `:306-308`).
- **Supply chain — dependency pinning:** every `protoc` binary in `build.zig.zon:9-45` is pinned by explicit official URL **and** content `hash` with `lazy = true`; Zig's package manager verifies the hash on fetch. The published-package `.paths` (`build.zig.zon:46-57`) deliberately exclude `scripts/`, `bench/`, and `.pre-commit-config.yaml`, so the Python/shell tooling is **not shipped to consumers**, shrinking the distributed attack surface.
- **No shell/`eval` injection in tooling:** `utils/build_util.zig` spawns `protoc`/`zig fmt` via `std.process.spawn` with an argv array (no shell) over developer-controlled paths (`:199-217`). `scripts/*.py` are stdlib-only with no `subprocess`/`eval`/`os.system` and parse local developer/CI files; `scripts/*.sh` use `set -euo pipefail`, array argv, and operate on operator-supplied git refs.
- **Observability seam is inert by default and leak-free:** `src/observability.zig:27` hardcodes `enabled = false`; all span types are zero-sized no-ops and every emit path is `catch`-discarded. No key/PII/secret material is logged; `observability_init.zig` is only compiled under `-Dwith_otel=true` (default false, `build.zig:66`) and reads only `OTEL_*` config, logging init failures without sensitive values.
- **Code generator escaping:** string/bytes defaults are emitted through `std.zig.fmtString` (`bootstrapped-generator/main.zig:1023-1028`); doc comments are split on `\n` and each line re-prefixed with `///` (`:49-72`), preventing line-comment breakout; identifiers go through `escapeName` for Zig keywords. Field/enum names are additionally constrained by `protoc`'s own identifier validation upstream.
- **Fuzz harness exists** (`tests/fuzz_decode.zig`) asserting "no panic/hang/leak/corruption" on mutated bytes against a representative message — a strong foundation; widening its input cap and seeding a corpus would let it reach PB-2026-001/002.

---

## 6. Coverage Gaps & Questions

- **JSON `parse` unwraps `options.max_value_len.?`** (`src/json.zig:31`, `:388`). Via the generated `jsonDecode`/`std.json.parseFromSlice` path the option is defaulted upstream, so it is safe in normal use. If a caller invokes `protobuf.json.parse`/`jsonParse` directly with a hand-built `ParseOptions` where `max_value_len == null`, this `.?` panics. This is caller-supplied configuration (not attacker-controlled wire data), so it is recorded as a question, not a finding. *Question:* are consumers ever expected to call `json.parse` directly with custom options? If so, consider defaulting `max_value_len` defensively.
- **Build-time codegen trust:** the generator (`bootstrapped-generator/main.zig`) turns a `CodeGeneratorRequest` from stdin into Zig source. No concrete unescaped sink found that allows code injection from a malicious `.proto`/descriptor (comments and string defaults are escaped; identifiers are protoc-validated). Not exhaustively proven that *every* descriptor-derived string reaching the output is newline-safe. *Question:* is the generator ever run against third-party/untrusted `.proto` or pre-built descriptor sets, or only first-party schemas? If untrusted descriptors are in scope, a dedicated fuzz/property test over `CodeGeneratorRequest` → generated-source escaping would be warranted.
- **Build mode of downstream consumers:** PB-2026-002's outcome (hard panic vs. masked `InvalidInput`) depends on optimize mode. *Question:* what `-Doptimize` do production consumers use?
- **`pre-commit` `detect-private-key` excludes `tests/`, `src/tests/`, `docker/zig-packages/`, `certs/`** (`.pre-commit-config.yaml:40`). For this repo those are fixture directories, so the exclusion is reasonable, but it means a key accidentally committed under `tests/` would not be flagged. Not a finding (no secret observed); noted for hygiene.
- **Not executed:** did not build, run the test suite, run `--fuzz`, or execute any script (read-only review). The findings are derived from source analysis and the decoder's own unit tests; dynamic confirmation (e.g. a PoC byte string driving `decode()` to crash under ReleaseSafe) is recommended as the regression-test step for PB-2026-001/002.
- **Not in scope / not present:** no network, auth, session, SQL/OS/template injection, SSRF, or deserialization-of-attacker-types surface exists in this library.

---

## 7. Prioritized Next Actions

1. **Fix PB-2026-001** — add a depth cap to `skipField` (thread `_depth`, reuse `max_decode_depth`) and add a nested-group hardening test. *(Highest priority: unbounded recursion reachable from the public streaming `decode()` with no input-size ceiling.)*
2. **Fix PB-2026-002** — add `if (len < 0) return error.InvalidInput;` before `@intCast(len)` at `src/wire.zig:845` and `:878`; add packed and non-packed negative-length regression tests. *(Same fix shape as four already-guarded branches; low effort, removes a Debug/ReleaseSafe panic.)*
3. **Harden the fuzz harness** to reach these classes: raise the 4 KiB input cap in `tests/fuzz_decode.zig` (or add a dedicated long-`0x0B` / negative-length case) and seed a corpus from `tests/fixtures/*`.
4. **Fix PB-2026-003** — pin the CI Zig toolchain by SHA-256 (and ideally minisign), failing closed on mismatch.
5. **Resolve the §6 questions** — confirm whether `json.parse` is called directly with custom options and whether the generator is ever run on untrusted descriptors; add a `max_value_len` default and/or generator escaping fuzz test if either is in scope.
6. **Lock in the verified closures** by keeping the existing hardening tests and extending them to the two new cases, so PB-2026-001/002 cannot silently regress alongside the already-closed S1/S3/N1 mitigations.
