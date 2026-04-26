//! zig-protobuf bench harness — entry point for `zig build bench-*`.
//!
//! Composes the scenario registries from the scenarios_*.zig files
//! and dispatches to the right scenario(s) based on `--scenario <id>`.
//! When no scenario is selected, runs every scenario whose layer
//! matches the build-time `bench_layer` option (set by build.zig).
//!
//! Stdlib only — no third-party benchmark library, per the
//! native-benchmarks hard rules.

const std = @import("std");
const framework = @import("framework.zig");
const decode_scenarios = @import("scenarios_decode.zig");
const encode_scenarios = @import("scenarios_encode.zig");
const integration_scenarios = @import("scenarios_integration.zig");

const build_options = @import("build_options");

/// Layer filter selected at build time. The build steps configure
/// this so `bench-micro` runs only micro scenarios, `bench-integration`
/// runs only integration scenarios, and `bench-ci` / `bench-smoke`
/// run both. Comparison scenarios are driven externally by the AB
/// runner script and therefore never come through this entry point.
const LayerFilter = enum {
    micro,
    integration,
    all,
    smoke,
};

const layer_filter: LayerFilter = std.meta.stringToEnum(
    LayerFilter,
    build_options.bench_layer,
) orelse .all;

pub fn main(init: std.process.Init.Minimal) !void {
    const io = std.Io.Threaded.global_single_threaded.io();

    // The bench harness uses smp_allocator instead of DebugAllocator.
    // The bench is single-threaded, allocations are short-lived, and
    // the harness is hot-path-sensitive — leak detection would only
    // add overhead and noisy stderr warnings on process exit.
    // CountingAllocator wraps this for the per-scenario zero-alloc
    // probes, so the alloc-budget contract is still enforced.
    const allocator = std.heap.smp_allocator;

    var opts = try framework.parseArgs(allocator, init.args);
    defer freeOpts(allocator, &opts);
    opts.git_sha = try framework.resolveGitSha(allocator, init.environ);

    // bench-smoke build step always overrides --smoke regardless of
    // CLI to keep the smoke runtime budget tight.
    if (layer_filter == .smoke) {
        opts.smoke = true;
    }

    // Build a flat list of all known scenarios in display order.
    var registry: std.ArrayListUnmanaged(framework.Scenario) = .empty;
    defer registry.deinit(allocator);

    inline for (decode_scenarios.all) |s| try registry.append(allocator, s);
    inline for (encode_scenarios.all) |s| try registry.append(allocator, s);
    inline for (integration_scenarios.all) |s| try registry.append(allocator, s);

    var ran_any = false;
    for (registry.items) |scenario| {
        if (!includesLayer(scenario.layer)) continue;
        if (opts.scenario) |id| {
            if (!std.mem.eql(u8, id, scenario.id)) continue;
        }
        std.debug.print("bench: running scenario={s} layer={s}\n", .{
            scenario.id,
            @tagName(scenario.layer),
        });
        try scenario.run(io, allocator, opts, &scenario);
        ran_any = true;
    }

    if (!ran_any) {
        if (opts.scenario) |id| {
            std.debug.print(
                "bench: no scenario matched id='{s}' under layer-filter={s}\n",
                .{ id, @tagName(layer_filter) },
            );
            std.process.exit(2);
        } else {
            std.debug.print(
                "bench: no scenarios in layer-filter={s}\n",
                .{@tagName(layer_filter)},
            );
            std.process.exit(2);
        }
    }
}

fn includesLayer(layer: framework.Layer) bool {
    return switch (layer_filter) {
        .all, .smoke => true,
        .micro => layer == .micro,
        .integration => layer == .integration,
    };
}

fn freeOpts(allocator: std.mem.Allocator, opts: *framework.RunOptions) void {
    if (opts.scenario) |s| allocator.free(s);
    if (opts.out_dir_owned) allocator.free(opts.out_dir);
    // resolveGitSha returns the literal "unknown" when the env var
    // is absent — only free heap-owned slices.
    if (!std.mem.eql(u8, opts.git_sha, "unknown")) allocator.free(opts.git_sha);
}
