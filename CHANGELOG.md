# Changelog

All notable changes to this project will be documented in this file.
The format is loosely based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Security

- Fixed double-free in `decodeRepeated` slice path that could be
  reached on `repeated bytes` / `repeated string` decode under
  `result.append` OOM. Eliminated a heap-corruption / RCE primitive.
  (S3, commit `b88d845`)
- `skipField` now properly skips proto2 groups instead of silently
  consuming zero bytes; closes a CPU infinite-loop DoS on malformed
  input (CWE-835). Stray `egroup` returns `error.InvalidInput`.
  (N1, commit `92c5a59`)
- `Tag.decode` rejects field number 0 per the protobuf spec (CWE-20).
  (N8, commit `a13c854`)

### Fixed

- Removed orphan `protoc-linux-64` dependency entry that pointed at the
  Windows zip; cleaned up `build.zig.zon`. (GAP-PB-001)
- Re-enabled the previously-disabled `optional_sint32` / `optional_sint64`
  round-trip assertions in `tests/optionals.zig`. The original TODO had
  the expected values wrong; the zigzag decoder was correct all along.
  (GAP-PB-002)
- Removed dead `printAllDecoded` helper that referenced the undefined
  `protobuf.WireDecoderIterator`. (GAP-PB-003)

### Added

- GitLab CI pipeline (`.gitlab-ci.yml`) running `zig fmt --check`,
  `zig build`, and `zig build test` on Zig 0.16.0. (GAP-PB-004)
- `SECURITY.md` documenting trust boundaries and the vulnerability
  reporting process.
- `CONTRIBUTING.md` covering local setup, conventions, and workflow.
- `.editorconfig` for editor-agnostic indentation.
- `///` doc comments on the public JSON API, `DecodingError`,
  `deinitField`, and `ZigZag`. (GAP-PB-018)

### Removed

- Dead extraction types and helpers in `src/protobuf.zig`
  (`ExtractedDataTag`, `ExtractedData`, `Extracted`, `DecodedVarint`,
  `decode_varint`, `decode_fixed`) and their tests; runtime decode flows
  through `src/wire.zig.decodeScalar`. (GAP-PB-012)
- `isEnvVarTruthy` no-op stub in `utils/build_util.zig`. (GAP-PB-017)
- Six unused build-script imports plus a redundant `addImport` call in
  `build.zig`. (GAP-PB-019, Q-12)
- Unused `testing` and `unittest` imports in `tests/integration.zig`.
  (GAP-PB-020, Q-13)
- Unused `warn` import in `bootstrapped-generator/main.zig`. (Q-14)
- `.devcontainer` and `.github` references from `build.zig.zon`'s
  `paths` whitelist (neither directory exists in the repo).
  (GAP-PB-022)

### Documentation

- `README.md` install snippet now points at the current GitLab origin
  (`gitlab.com/devnw/zig/protobuf`) instead of the upstream Arwalk fork.
  (GAP-PB-016)
- Full audit reports added under `docs/`: `AUDIT_SUMMARY.md`,
  `GAP_ANALYSIS.md`, `GAP_ANALYSIS_RESOLVED.md`, `QUALITY_GAP_ANALYSIS.md`,
  `PERF_GAP_ANALYSIS.md`, `SECURITY_GAP_ANALYSIS.md`.

## [3.0.0] - prior to 2026-04-26

The 3.0 cycle covers the migration from Zig 0.15.x to Zig 0.16.0.

- `fix: zig 0.16.0 compat` (`f18747d`, `462740b`)
- `fix: intToEnum → @enumFromInt for zig 0.16.0` (`78fc12a`)
- `fix: migrate to zig 0.16.0 API` (`c02f3aa`)
- `fix: Update API for Zig 0.15.2 compatibility` (`53ece58`)

See `git log` for the complete history prior to this CHANGELOG.
