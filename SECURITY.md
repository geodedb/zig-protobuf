# Security Policy

## Scope

`zig-protobuf` is consumed in-process by host applications. The runtime
attack surface is whatever your application chooses to feed into:

1. **Wire decoder** — `protobuf.decode(T, reader, allocator)` (and the
   per-message `T.decode(reader, allocator)` trampolines emitted by
   `protoc-gen-zig`). All bytes from the reader are treated as
   untrusted.
2. **JSON parser** — `protobuf.json.parse` / `protobuf.json.decode` /
   the per-message `T.jsonParse` and `T.jsonDecode` trampolines. The
   incoming JSON byte buffer is treated as untrusted.
3. **Generator stdin** (build-time only) —
   `bootstrapped-generator/main.zig` (`protoc-gen-zig`) reads a
   `CodeGeneratorRequest` from stdin under the protoc plugin protocol.
   This runs on a developer or CI workstation; the trust boundary is
   "the `.proto` files and protoc invocation are trusted by the build
   system author".

The library does not open sockets, listen on the network, fork
subprocesses, or write files outside the build-time generator path.
Build helpers in `utils/build_util.zig` operate exclusively on paths
provided by the consuming `build.zig`.

## Reporting a vulnerability

Please open a confidential issue at
<https://gitlab.com/devnw/zig/protobuf/-/issues/new>. Mark the issue as
confidential before submitting so the report is not visible publicly
while a fix is in flight. If you cannot reach GitLab, email the
maintainer directly and a confidential issue will be opened on your
behalf.

When filing, please include:

- A minimal reproducer (Zig snippet plus, where relevant, a base64 or
  hex dump of the malformed wire/JSON bytes).
- The Zig version (`zig version`) and target triple.
- The expected vs. observed behavior (crash, hang, OOM, UB, etc.).
- Any guess at impact (DoS, information disclosure, memory corruption,
  RCE).

We aim to acknowledge reports within five business days. After triage,
we will work with the reporter on a coordinated disclosure timeline.

## Hardening expectations

The decoder is intended to be safe against malformed input:

- Wire-type validation is enforced at every field-dispatch site.
- Negative length prefixes are rejected before any allocation.
- Field number 0 is rejected at tag decode (per the spec).
- proto2 groups (`sgroup`/`egroup`) skip is bounded by the matching
  tag rule; stray `egroup` is rejected.
- The `decodeRepeated` slice path no longer registers a duplicate
  `errdefer` (CVE-class double-free closed in commit `b88d845`).

Known hardening work in flight (tracked in `docs/SECURITY_GAP_ANALYSIS.md`):

- Configurable recursion depth limit on `decodeMessage` (CWE-674).
- Configurable per-field and cumulative allocation caps (CWE-789).
- Element-count caps on packed/repeated decoding.
- Optional UTF-8 validation on `string` fields.

## Supply chain

All build-time `protoc` binaries are pinned in `build.zig.zon` by SHA-256
content hash. `lazy = true` means consumers do not download `protoc`
unless they invoke `RunProtocStep`. Tampering with the upstream tarball
breaks the build.
