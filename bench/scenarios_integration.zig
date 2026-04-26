//! Integration scenarios — full encode/decode/dupe pipelines exercised
//! against real-world fixture binaries.
//!
//! The fixtures (`tests/fixtures/vector_tile.bin`, `graphics.bin`) are
//! checked into the repo; the bench harness reads them from disk
//! relative to CWD so that the bench binary works under both
//! `zig build bench-integration` (CWD = repo root) and the AB
//! runner's worktree mode (CWD = worktree-{a,b}/).

const std = @import("std");
const protobuf = @import("protobuf");
const framework = @import("framework.zig");

const vector_tile = @import("vector_tile.pb.zig");
const graphics_pb = @import("graphics.pb.zig");

const sink = framework.sink;

/// Read a fixture file into a freshly-allocated slice. Fails loudly
/// with a clear error if the file is missing rather than panicking
/// mid-bench.
fn loadFixture(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const cwd = std.Io.Dir.cwd();
    return cwd.readFileAlloc(io, path, allocator, .unlimited) catch |err| {
        std.debug.print(
            "FATAL: bench fixture missing or unreadable at '{s}' (error={s}). Run from the repo root so tests/fixtures/ is reachable.\n",
            .{ path, @errorName(err) },
        );
        return err;
    };
}

const FixtureCtx = struct {
    bytes: []const u8,
    allocator: std.mem.Allocator,
};

fn decodeVectorTileBody(ctx: *FixtureCtx) !void {
    var reader: std.Io.Reader = .fixed(ctx.bytes);
    var decoded = try vector_tile.Tile.decode(&reader, ctx.allocator);
    defer decoded.deinit(ctx.allocator);
    sink(usize, decoded.layers.items.len);
}

fn encodeVectorTileRoundtripBody(ctx: *FixtureCtx) !void {
    var reader: std.Io.Reader = .fixed(ctx.bytes);
    var decoded = try vector_tile.Tile.decode(&reader, ctx.allocator);
    defer decoded.deinit(ctx.allocator);

    var w: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer w.deinit();
    try decoded.encode(&w.writer, ctx.allocator);
    sink(usize, w.written().len);
}

fn dupeVectorTileBody(ctx: *FixtureCtx) !void {
    var reader: std.Io.Reader = .fixed(ctx.bytes);
    var decoded = try vector_tile.Tile.decode(&reader, ctx.allocator);
    defer decoded.deinit(ctx.allocator);

    var cloned = try decoded.dupe(ctx.allocator);
    defer cloned.deinit(ctx.allocator);
    sink(usize, cloned.layers.items.len);
}

fn decodeGraphicsBody(ctx: *FixtureCtx) !void {
    var reader: std.Io.Reader = .fixed(ctx.bytes);
    var decoded = try graphics_pb.GraphicsDB.decode(&reader, ctx.allocator);
    defer decoded.deinit(ctx.allocator);
    sink(*graphics_pb.GraphicsDB, &decoded);
}

const JsonRoundtripCtx = struct {
    json_bytes: []const u8,
    allocator: std.mem.Allocator,
};

fn jsonEncodeVectorTileBody(ctx: *FixtureCtx) !void {
    var reader: std.Io.Reader = .fixed(ctx.bytes);
    var decoded = try vector_tile.Tile.decode(&reader, ctx.allocator);
    defer decoded.deinit(ctx.allocator);

    const json_out = try decoded.jsonEncode(.{}, ctx.allocator);
    defer ctx.allocator.free(json_out);
    sink(usize, json_out.len);
}

fn jsonDecodeVectorTileBody(ctx: *JsonRoundtripCtx) !void {
    var parsed = try vector_tile.Tile.jsonDecode(ctx.json_bytes, .{}, ctx.allocator);
    defer parsed.deinit();
    sink(usize, parsed.value.layers.items.len);
}

fn runFixtureScenario(
    io: std.Io,
    allocator: std.mem.Allocator,
    opts: framework.RunOptions,
    scenario: *const framework.Scenario,
    fixture_path: []const u8,
    comptime body: fn (ctx: *FixtureCtx) anyerror!void,
) !void {
    const bytes = try loadFixture(io, allocator, fixture_path);
    defer allocator.free(bytes);

    var counting: framework.CountingAllocator = .init(allocator);
    const tracked = counting.allocator();

    var ctx: FixtureCtx = .{ .bytes = bytes, .allocator = tracked };

    if (opts.smoke) {
        try framework.smokeScenario(io, allocator, scenario, &counting, FixtureCtx, &ctx, body);
        return;
    }
    try framework.driveScenario(io, allocator, opts, scenario, &counting, FixtureCtx, &ctx, body);
}

fn runDecodeFixtureVectorTile(
    io: std.Io,
    allocator: std.mem.Allocator,
    opts: framework.RunOptions,
    scenario: *const framework.Scenario,
) !void {
    try runFixtureScenario(
        io,
        allocator,
        opts,
        scenario,
        "tests/fixtures/vector_tile.bin",
        decodeVectorTileBody,
    );
}

fn runEncodeFixtureVectorTileRoundtrip(
    io: std.Io,
    allocator: std.mem.Allocator,
    opts: framework.RunOptions,
    scenario: *const framework.Scenario,
) !void {
    try runFixtureScenario(
        io,
        allocator,
        opts,
        scenario,
        "tests/fixtures/vector_tile.bin",
        encodeVectorTileRoundtripBody,
    );
}

fn runDupeFixtureVectorTile(
    io: std.Io,
    allocator: std.mem.Allocator,
    opts: framework.RunOptions,
    scenario: *const framework.Scenario,
) !void {
    try runFixtureScenario(
        io,
        allocator,
        opts,
        scenario,
        "tests/fixtures/vector_tile.bin",
        dupeVectorTileBody,
    );
}

fn runDecodeFixtureGraphics(
    io: std.Io,
    allocator: std.mem.Allocator,
    opts: framework.RunOptions,
    scenario: *const framework.Scenario,
) !void {
    try runFixtureScenario(
        io,
        allocator,
        opts,
        scenario,
        "tests/fixtures/graphics.bin",
        decodeGraphicsBody,
    );
}

fn runDecodeFixtureGraphicsDeep(
    io: std.Io,
    allocator: std.mem.Allocator,
    opts: framework.RunOptions,
    scenario: *const framework.Scenario,
) !void {
    try runFixtureScenario(
        io,
        allocator,
        opts,
        scenario,
        "tests/fixtures/graphics.bin",
        decodeGraphicsBody,
    );
}

fn runJsonEncodeFixtureVectorTile(
    io: std.Io,
    allocator: std.mem.Allocator,
    opts: framework.RunOptions,
    scenario: *const framework.Scenario,
) !void {
    try runFixtureScenario(
        io,
        allocator,
        opts,
        scenario,
        "tests/fixtures/vector_tile.bin",
        jsonEncodeVectorTileBody,
    );
}

fn runJsonDecodeFixtureVectorTile(
    io: std.Io,
    allocator: std.mem.Allocator,
    opts: framework.RunOptions,
    scenario: *const framework.Scenario,
) !void {
    // First decode the fixture into a struct, JSON-encode it, then
    // measure decoding that JSON back. Encoding work happens once
    // outside the timed loop.
    const bytes = try loadFixture(io, allocator, "tests/fixtures/vector_tile.bin");
    defer allocator.free(bytes);

    var seed_reader: std.Io.Reader = .fixed(bytes);
    var seed_decoded = try vector_tile.Tile.decode(&seed_reader, allocator);
    defer seed_decoded.deinit(allocator);

    const json_bytes = try seed_decoded.jsonEncode(.{}, allocator);
    defer allocator.free(json_bytes);

    var counting: framework.CountingAllocator = .init(allocator);
    const tracked = counting.allocator();
    var ctx: JsonRoundtripCtx = .{ .json_bytes = json_bytes, .allocator = tracked };

    if (opts.smoke) {
        try framework.smokeScenario(io, allocator, scenario, &counting, JsonRoundtripCtx, &ctx, jsonDecodeVectorTileBody);
        return;
    }
    try framework.driveScenario(io, allocator, opts, scenario, &counting, JsonRoundtripCtx, &ctx, jsonDecodeVectorTileBody);
}

pub const all = [_]framework.Scenario{
    .{
        .id = "decode-fixture-vector-tile",
        .layer = .integration,
        .zero_alloc_expected = false,
        .default_iterations = 1,
        .input_bytes = 128_000,
        .run = runDecodeFixtureVectorTile,
    },
    .{
        .id = "encode-fixture-vector-tile-roundtrip",
        .layer = .integration,
        .zero_alloc_expected = false,
        .default_iterations = 1,
        .input_bytes = 128_000,
        .run = runEncodeFixtureVectorTileRoundtrip,
    },
    .{
        .id = "dupe-fixture-vector-tile",
        .layer = .integration,
        .zero_alloc_expected = false,
        .default_iterations = 1,
        .input_bytes = 128_000,
        .run = runDupeFixtureVectorTile,
    },
    .{
        .id = "decode-fixture-graphics",
        .layer = .integration,
        .zero_alloc_expected = false,
        .default_iterations = 1,
        .input_bytes = 1_153_433,
        .run = runDecodeFixtureGraphics,
    },
    .{
        .id = "decode-fixture-graphics-deep",
        .layer = .integration,
        .zero_alloc_expected = false,
        .default_iterations = 1,
        .input_bytes = 1_153_433,
        .run = runDecodeFixtureGraphicsDeep,
    },
    .{
        .id = "json-encode-fixture-vector-tile",
        .layer = .integration,
        .zero_alloc_expected = false,
        .default_iterations = 1,
        .input_bytes = 128_000,
        .run = runJsonEncodeFixtureVectorTile,
    },
    .{
        .id = "json-decode-fixture-vector-tile",
        .layer = .integration,
        .zero_alloc_expected = false,
        .default_iterations = 1,
        .input_bytes = 128_000,
        .run = runJsonDecodeFixtureVectorTile,
    },
};
