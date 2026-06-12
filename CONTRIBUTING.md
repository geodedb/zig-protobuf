# Contributing to zig-protobuf

Thanks for your interest in contributing. This document captures the
minimum you need to know to land a change.

## Development setup

- Zig **0.16.0** (the `master` branch tracks the latest stable Zig). The
  `zig-master` branch tracks Zig nightly.
- A network connection on first build to lazily fetch `protoc` 32.1
  (pinned in `build.zig.zon`).

```sh
git clone https://gitlab.com/devnw/zig/protobuf.git
cd protobuf
zig build test --summary all
```

## Workflow

1. Branch from `master` (`feat/short-name`, `fix/short-name`, etc.).
2. If you change a `.proto` schema, run `zig build` once so
   `tests/generated/` and `tests/.generated/` are regenerated. Commit
   the regenerated `.pb.zig` files alongside the schema change.
3. Run the local equivalent of CI:

   ```sh
   zig fmt --check build.zig src/ utils/ \
       bootstrapped-generator/main.zig bootstrapped-generator/FullName.zig \
       tests/tests.zig tests/tests_varints.zig tests/tests_fixedsizes.zig \
       tests/tests_complex_type.zig tests/tests_json.zig tests/oneof.zig \
       tests/optionals.zig tests/alltypes.zig tests/leaks.zig \
       tests/graphics.zig tests/mapbox.zig tests/integration.zig
   zig build -Doptimize=Debug
   zig build test --summary all
   ```

4. Open a merge request against `master`. The `.gitlab-ci.yml` pipeline
   will run the same three jobs.

## Coding conventions

- `zig fmt` is the source of truth for formatting; CI enforces it.
- Public types use `PascalCase`; functions use `camelCase`. (Some older
  helpers still use `snake_case`; new code should use `camelCase`.)
- Prefer `///` doc comments on every public symbol; `//!` for
  module-level documentation.
- Keep the public API surface in `src/protobuf.zig` stable. Generator-
  emitted method signatures (`encode`, `decode`, `deinit`, `dupe`,
  `jsonEncode`, `jsonDecode`, `jsonParse`, `jsonStringify`) must remain
  byte-compatible with existing consumers.

## Tests

- Hand-written tests live under `tests/`. Each top-level `.zig` file is
  wired into `build.zig` as its own `addTest` artifact.
- Generated `.pb.zig` files are committed (`tests/generated/`) but also
  regenerated on every `zig build`; do not edit them by hand.
- New fixtures should be small (binary fixtures live in
  `tests/fixtures/`; `.proto` sources in `tests/protos_for_test/`).

## Security-sensitive changes

If you are touching the wire decoder (`src/wire.zig`), the JSON parser
(`src/json.zig`), or the generator (`bootstrapped-generator/main.zig`),
please read `SECURITY.md` and reference any relevant entries in
`docs/SECURITY_GAP_ANALYSIS.md`. Decoder changes that affect untrusted
input handling should include regression tests covering the malformed
case.

## Commit messages

- Imperative mood, ≤72-char subject (`fix: …`, `feat: …`, `docs: …`,
  `chore: …`, `ci: …`, `test: …`).
- Reference the gap or issue ID where relevant
  (`fix: close GAP-PB-001 - …`).
- Body explains *why* the change is correct, not what it does (the diff
  shows what).
