const std = @import("std");
const build_util = @import("utils/build_util.zig");
pub const RunProtocStep = build_util.RunProtocStep;

const PROTOC_VERSION = build_util.PROTOC_VERSION;

pub fn build(b: *std.Build) !void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    // Feature-flag build options — every optimization called out in
    // docs/performance/2026-04-26-encode-decode-baseline/plan.json
    // ("feature_flag_contract") gets a -D toggle so the AB runner can
    // flip an optimization off on the candidate ref to confirm the
    // measured delta is caused by the optimization. The defaults are
    // all true; the AB-disable run flips one flag to false.
    const opt_use_fast_varint = b.option(
        bool,
        "use-fast-varint",
        "Enable the P-02 fast-path varint decoder (default: true)",
    ) orelse true;
    const opt_use_single_pass_submessage = b.option(
        bool,
        "use-single-pass-submessage",
        "Enable the P-01 single-pass writeSubmessage (default: true)",
    ) orelse true;
    const opt_use_fast_tag_dispatch = b.option(
        bool,
        "use-fast-tag-dispatch",
        "Enable the P-03 inline-for tag dispatch (default: true)",
    ) orelse true;
    const opt_use_inline_packed_write = b.option(
        bool,
        "use-inline-packed-write",
        "Enable the P-04 inline packed-list writer (default: true)",
    ) orelse true;
    const opt_use_ensure_capacity_packed = b.option(
        bool,
        "use-ensure-capacity-packed",
        "Enable the P-05 ensureTotalCapacity in decodeRepeated (default: true)",
    ) orelse true;
    const opt_use_fast_json_key_dispatch = b.option(
        bool,
        "use-fast-json-key-dispatch",
        "Enable the P-08 fast JSON key dispatch (default: true)",
    ) orelse true;
    const opt_use_direct_json_encode = b.option(
        bool,
        "use-direct-json-encode",
        "Enable the P-09 direct JSON encode (default: true)",
    ) orelse true;

    // -Dwith_otel=<bool> compiles in the otel observability seam. When
    // false (the default), the otel dependency is never resolved and no
    // otel symbols are imported — the static library link contains zero
    // `otel`/`observability` symbols. Verified by
    // otel/scripts/verify-consumer-noop.sh.
    const with_otel = b.option(
        bool,
        "with_otel",
        "Compile in otel instrumentation (off by default; zero overhead when off)",
    ) orelse false;

    // Forward otel build options so the upstream package is configured
    // identically across all consumers in the build graph. Without this,
    // each consumer's `b.lazyDependency("otel", ...)` materialises a
    // DISTINCT otel Module instance (different `build_options` ⇒ different
    // package keys), and zig 0.16 errors with `file exists in modules
    // 'otel' and 'otel0'` when transitive imports overlap.
    const otel_use_devnw_tls = b.option(
        bool,
        "otel_use_devnw_tls",
        "Forward to upstream otel: HTTPS via DevNW tls",
    ) orelse false;
    const otel_disabled = b.option(
        bool,
        "otel_disabled",
        "Forward to upstream otel: comptime-disable",
    ) orelse false;
    const otel_profiles = b.option(
        bool,
        "otel_profiles",
        "Forward to upstream otel: experimental profiles",
    ) orelse false;
    const otel_use_devnw_grpc = b.option(
        bool,
        "otel_use_devnw_grpc",
        "Forward to upstream otel: DevNW gRPC",
    ) orelse false;

    // Helper that builds a fresh build_options module. Each consumer
    // (lib root_module, protobuf module, every test artifact, every
    // bench exe) gets its own instance so they can be tuned
    // independently if needed; for now they share the same value set.
    const buildProtobufOptions = struct {
        fn create(
            bb: *std.Build,
            fast_varint: bool,
            single_pass_submessage: bool,
            fast_tag_dispatch: bool,
            inline_packed_write: bool,
            ensure_capacity_packed: bool,
            fast_json_key_dispatch: bool,
            direct_json_encode: bool,
            otel_enabled: bool,
        ) *std.Build.Module {
            const bo = bb.addOptions();
            bo.addOption(bool, "use_fast_varint", fast_varint);
            bo.addOption(bool, "use_single_pass_submessage", single_pass_submessage);
            bo.addOption(bool, "use_fast_tag_dispatch", fast_tag_dispatch);
            bo.addOption(bool, "use_inline_packed_write", inline_packed_write);
            bo.addOption(bool, "use_ensure_capacity_packed", ensure_capacity_packed);
            bo.addOption(bool, "use_fast_json_key_dispatch", fast_json_key_dispatch);
            bo.addOption(bool, "use_direct_json_encode", direct_json_encode);
            bo.addOption(bool, "with_otel", otel_enabled);
            return bo.createModule();
        }
    }.create;

    const lib_options = buildProtobufOptions(
        b,
        opt_use_fast_varint,
        opt_use_single_pass_submessage,
        opt_use_fast_tag_dispatch,
        opt_use_inline_packed_write,
        opt_use_ensure_capacity_packed,
        opt_use_fast_json_key_dispatch,
        opt_use_direct_json_encode,
        with_otel,
    );

    const lib = b.addLibrary(.{
        .name = "zig-protobuf",
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/protobuf.zig"),
            .target = target,
            .optimize = optimize,
        }),

        .linkage = .static,
    });
    lib.root_module.addImport("build_options", lib_options);

    // This declares intent for the library to be installed into the standard
    // location when the user invokes the "install" step (the default step when
    // running `zig build`).
    b.installArtifact(lib);

    const module = b.addModule("protobuf", .{
        .root_source_file = b.path("src/protobuf.zig"),
        .target = target,
        .optimize = optimize,
    });
    // Share `lib_options` with the protobuf module so any compile unit
    // that pulls in BOTH (e.g. an observability test that imports
    // `protobuf` and `build_options`) sees a single `build_options`
    // module instance. Reaching the same source file via two distinct
    // module instances is a hard compile error in Zig.
    module.addImport("build_options", lib_options);

    // When -Dwith_otel=true, resolve the otel dependency and surface it
    // to the protobuf module so `src/observability.zig` can pull
    // `@import("otel")`. The lazy() call only triggers a fetch when the
    // flag is true; the disabled build never reaches the dependency
    // resolver, so the otel package never shows up on disk. protobuf
    // itself does not call any seam function — the seam is exposed for
    // consumer-side wiring and forward compatibility.
    if (with_otel) {
        if (b.lazyDependency("otel", .{
            .target = target,
            .optimize = optimize,
            .otel_use_devnw_tls = otel_use_devnw_tls,
            .otel_disabled = otel_disabled,
            .otel_profiles = otel_profiles,
            .otel_use_devnw_grpc = otel_use_devnw_grpc,
        })) |otel_dep| {
            module.addImport("otel", otel_dep.module("otel"));
            lib.root_module.addImport("otel", otel_dep.module("otel"));
        }
    }

    const exe = build_util.buildGenerator(b, .{
        .target = target,
        .optimize = optimize,
    });

    // This declares intent for the executable to be installed into the
    // standard location when the user invokes the "install" step (the default
    // step when running `zig build`).
    b.installArtifact(exe);

    const test_step = b.step("test", "Run library tests");

    const tests = [_]*std.Build.Step.Compile{
        b.addTest(.{ .name = "protobuf", .root_module = module }),
        b.addTest(.{
            .name = "bootstrap",
            .root_module = b.createModule(.{
                .root_source_file = b.path("bootstrapped-generator/main.zig"),
                .target = target,
                .optimize = optimize,
            }),
        }),
        b.addTest(.{
            .name = "tests",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/tests.zig"),
                .target = target,
                .optimize = optimize,
            }),
        }),
        b.addTest(.{
            .name = "alltypes",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/alltypes.zig"),
                .target = target,
                .optimize = optimize,
            }),
        }),
        b.addTest(.{
            .name = "integration",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/integration.zig"),
                .target = target,
                .optimize = optimize,
            }),
        }),
        b.addTest(.{
            .name = "fixedsizes",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/tests_fixedsizes.zig"),
                .target = target,
                .optimize = optimize,
            }),
        }),
        b.addTest(.{
            .name = "varints",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/tests_varints.zig"),
                .target = target,
                .optimize = optimize,
            }),
        }),
        b.addTest(.{
            .name = "json",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/tests_json.zig"),
                .target = target,
                .optimize = optimize,
            }),
        }),
        b.addTest(.{
            .name = "FullName",
            .root_module = b.createModule(.{
                .root_source_file = b.path("bootstrapped-generator/FullName.zig"),
                .target = target,
                .optimize = optimize,
            }),
        }),
        b.addTest(.{
            .name = "complex_type",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/tests_complex_type.zig"),
                .target = target,
                .optimize = optimize,
            }),
        }),
        b.addTest(.{
            .name = "fuzz_decode",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/fuzz_decode.zig"),
                .target = target,
                .optimize = optimize,
            }),
        }),
        b.addTest(.{
            .name = "observability_disabled",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/observability_disabled_test.zig"),
                .target = target,
                .optimize = optimize,
            }),
        }),
        b.addTest(.{
            .name = "observability_enabled",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/observability_enabled_test.zig"),
                .target = target,
                .optimize = optimize,
            }),
        }),
    };

    const convertStep = RunProtocStep.create(b, target, .{
        .destination_directory = b.path("tests/.generated"),
        .source_files = &.{"tests/protos_for_test/generated_in_ci.proto"},
        .include_directories = &.{"tests/protos_for_test"},
    });

    const convertStep2 = RunProtocStep.create(b, target, .{
        .destination_directory = b.path("tests/generated"),
        .source_files = &.{ "tests/protos_for_test/all.proto", "tests/protos_for_test/whitespace-in-name.proto", "tests/protos_for_test/complex_type.proto" },
        .include_directories = &.{"tests/protos_for_test"},
    });

    for (tests) |test_item| {
        // The "protobuf" test imports src/protobuf.zig as its root module,
        // so re-adding it as a named import would create a self-referential
        // module graph. All other test artifacts need it to satisfy
        // `@import("protobuf")` from generated `.pb.zig`.
        if (!std.mem.eql(u8, "protobuf", test_item.name)) {
            test_item.root_module.addImport("protobuf", module);
        }

        // The observability tests directly inspect `build_options.with_otel`
        // (the seam disabled-no-op test reads the flag to assert
        // default-false; the enabled smoke test reads it to gate skip).
        // We reuse the same `lib_options` module the protobuf module
        // already pulls in — Zig refuses to compile a translation unit
        // that reaches the same source file via two distinct module
        // instances, so we must share, not re-create.
        if (std.mem.startsWith(u8, test_item.name, "observability_")) {
            test_item.root_module.addImport("build_options", lib_options);
            if (with_otel) {
                if (b.lazyDependency("otel", .{
                    .target = target,
                    .optimize = optimize,
                    .otel_use_devnw_tls = otel_use_devnw_tls,
                    .otel_disabled = otel_disabled,
                    .otel_profiles = otel_profiles,
                    .otel_use_devnw_grpc = otel_use_devnw_grpc,
                })) |otel_dep| {
                    test_item.root_module.addImport("otel", otel_dep.module("otel"));
                }
            }
        }

        // This creates a build step. It will be visible in the `zig build --help` menu,
        // and can be selected like this: `zig build test`
        // This will evaluate the `test` step rather than the default, which is "install".
        const run_main_tests = b.addRunArtifact(test_item);

        test_item.step.dependOn(&convertStep.step);
        test_item.step.dependOn(&convertStep2.step);

        test_step.dependOn(&run_main_tests.step);
    }

    const include = if (try build_util.getProtocDependency(b)) |protoc| protoc.path("include").getPath(b) else std.fs.path.dirname(@src().file) orelse ".";

    const bootstrap = b.step("bootstrap", "run the generator over its own sources");

    const bootstrapConversion = RunProtocStep.create(b, target, .{
        .destination_directory = b.path("bootstrapped-generator"),
        .source_files = &.{
            b.pathJoin(&.{ include, "google/protobuf/compiler/plugin.proto" }),
            b.pathJoin(&.{ include, "google/protobuf/descriptor.proto" }),
        },
        .include_directories = &.{},
    });

    bootstrap.dependOn(&bootstrapConversion.step);

    // Bench harness — see docs/performance/2026-04-26-encode-decode-baseline/
    // for the architecture and plan that drove this layout.
    //
    // Default to ReleaseFast for meaningful numbers, but allow override
    // via `-Doptimize=Debug` for development. (As of Zig 0.16.0 the
    // compiler ICEs on ReleaseFast for this tiny exe; ReleaseSafe is
    // a safe default that still benefits from the compiler's
    // optimizations.)
    // TODO: retry ReleaseFast on the next Zig point release.
    const bench_optimize: std.builtin.OptimizeMode = if (b.user_input_options.contains("optimize"))
        optimize
    else
        .ReleaseSafe;

    // (Feature-flag -D options are declared at the top of build() so
    // both the protobuf module and the bench exes share the same
    // value set. See `buildProtobufOptions` above.)

    // Generated message modules used by integration scenarios. The
    // bench exe needs `vector_tile.pb.zig` and `graphics.pb.zig`,
    // which already live under tests/generated/ from the test build.
    // Both depend on the public `protobuf` module.
    const vector_tile_module = b.createModule(.{
        .root_source_file = b.path("tests/generated/vector_tile.pb.zig"),
        .target = target,
        .optimize = bench_optimize,
    });
    vector_tile_module.addImport("protobuf", module);

    const graphics_module = b.createModule(.{
        .root_source_file = b.path("tests/generated/graphics.pb.zig"),
        .target = target,
        .optimize = bench_optimize,
    });
    graphics_module.addImport("protobuf", module);

    // Per-step bench executables: each gets its own build_options
    // module so that a layer-filter constant baked into bench/main.zig
    // can dispatch to the right scenarios. Sharing one exe wouldn't
    // work because Zig's build_options are per-module.
    const BenchExeSpec = struct {
        step_name: []const u8,
        description: []const u8,
        layer_label: []const u8,
        argv: []const []const u8,
    };
    const bench_specs = [_]BenchExeSpec{
        .{
            .step_name = "bench-micro",
            .description = "Run micro bench layer (deterministic byte literals, zero-alloc probes)",
            .layer_label = "micro",
            .argv = &.{ "--rounds", "10", "--warmups", "1", "--out", "raw/" },
        },
        .{
            .step_name = "bench-integration",
            .description = "Run integration bench layer (real fixtures, allocator active)",
            .layer_label = "integration",
            .argv = &.{ "--rounds", "5", "--warmups", "1", "--out", "raw/" },
        },
        .{
            .step_name = "bench-ci",
            .description = "Run micro + CI-safe integration in one shot (< 60s)",
            .layer_label = "all",
            .argv = &.{ "--rounds", "10", "--warmups", "1", "--out", "raw/" },
        },
        .{
            .step_name = "bench-smoke",
            .description = "One-round smoke pass over every scenario (no output files)",
            .layer_label = "smoke",
            .argv = &.{},
        },
    };

    inline for (bench_specs) |spec| {
        const step = b.step(spec.step_name, spec.description);

        const bo = b.addOptions();
        bo.addOption(bool, "use_fast_varint", opt_use_fast_varint);
        bo.addOption(bool, "use_single_pass_submessage", opt_use_single_pass_submessage);
        bo.addOption(bool, "use_fast_tag_dispatch", opt_use_fast_tag_dispatch);
        bo.addOption(bool, "use_inline_packed_write", opt_use_inline_packed_write);
        bo.addOption(bool, "use_ensure_capacity_packed", opt_use_ensure_capacity_packed);
        bo.addOption(bool, "use_fast_json_key_dispatch", opt_use_fast_json_key_dispatch);
        bo.addOption(bool, "use_direct_json_encode", opt_use_direct_json_encode);
        bo.addOption([]const u8, "bench_layer", spec.layer_label);

        const bench_exe = b.addExecutable(.{
            .name = spec.step_name,
            .root_module = b.createModule(.{
                .root_source_file = b.path("bench/main.zig"),
                .target = target,
                .optimize = bench_optimize,
            }),
        });
        bench_exe.root_module.addImport("protobuf", module);
        bench_exe.root_module.addImport("vector_tile.pb.zig", vector_tile_module);
        bench_exe.root_module.addImport("graphics.pb.zig", graphics_module);
        bench_exe.root_module.addImport("build_options", bo.createModule());

        const run = b.addRunArtifact(bench_exe);
        if (spec.argv.len > 0) run.addArgs(spec.argv);
        if (b.args) |user_args| run.addArgs(user_args);

        step.dependOn(&run.step);
    }

    // Legacy `zig build bench` — keep it as an alias of bench-micro so
    // the smoke command from the prior README still works.
    const legacy_step = b.step("bench", "Alias for bench-micro (legacy entry point)");
    {
        const bo = b.addOptions();
        bo.addOption(bool, "use_fast_varint", opt_use_fast_varint);
        bo.addOption(bool, "use_single_pass_submessage", opt_use_single_pass_submessage);
        bo.addOption(bool, "use_fast_tag_dispatch", opt_use_fast_tag_dispatch);
        bo.addOption(bool, "use_inline_packed_write", opt_use_inline_packed_write);
        bo.addOption(bool, "use_ensure_capacity_packed", opt_use_ensure_capacity_packed);
        bo.addOption(bool, "use_fast_json_key_dispatch", opt_use_fast_json_key_dispatch);
        bo.addOption(bool, "use_direct_json_encode", opt_use_direct_json_encode);
        bo.addOption([]const u8, "bench_layer", "micro");

        const legacy_bench_exe = b.addExecutable(.{
            .name = "bench",
            .root_module = b.createModule(.{
                .root_source_file = b.path("bench/main.zig"),
                .target = target,
                .optimize = bench_optimize,
            }),
        });
        legacy_bench_exe.root_module.addImport("protobuf", module);
        legacy_bench_exe.root_module.addImport("vector_tile.pb.zig", vector_tile_module);
        legacy_bench_exe.root_module.addImport("graphics.pb.zig", graphics_module);
        legacy_bench_exe.root_module.addImport("build_options", bo.createModule());

        const run = b.addRunArtifact(legacy_bench_exe);
        run.addArgs(&.{ "--rounds", "1", "--warmups", "0", "--out", "raw/" });
        if (b.args) |user_args| run.addArgs(user_args);

        legacy_step.dependOn(&run.step);
    }
}
