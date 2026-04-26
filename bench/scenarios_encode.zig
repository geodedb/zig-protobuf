//! Micro encode scenarios — wire-level encode hot paths.
//!
//! Each scenario writes into a stack-allocated `[16]u8` via
//! `std.Io.Writer.fixed`, so the timed loop never touches the heap.
//! This is the contract that protects P-07 (encode-scalar
//! stack-buffered) from silent regressions.

const std = @import("std");
const protobuf = @import("protobuf");
const framework = @import("framework.zig");

const sink = framework.sink;

const Ctx = struct { buf: [16]u8 };

fn encodeVarintU64Body1(ctx: *Ctx) !void {
    var w: std.Io.Writer = .fixed(&ctx.buf);
    try protobuf.writeRawVarint(&w, 1);
    sink([]const u8, w.buffered());
}

fn encodeVarintU64BodyMax(ctx: *Ctx) !void {
    var w: std.Io.Writer = .fixed(&ctx.buf);
    try protobuf.writeRawVarint(&w, std.math.maxInt(u64));
    sink([]const u8, w.buffered());
}

fn encodeFixed32Body(ctx: *Ctx) !void {
    var w: std.Io.Writer = .fixed(&ctx.buf);
    try protobuf.writeFixed(&w, @as(f32, 1.0));
    sink([]const u8, w.buffered());
}

fn encodeFixed64Body(ctx: *Ctx) !void {
    var w: std.Io.Writer = .fixed(&ctx.buf);
    try protobuf.writeFixed(&w, @as(f64, 1.0));
    sink([]const u8, w.buffered());
}

fn runEncodeScenario(
    io: std.Io,
    allocator: std.mem.Allocator,
    opts: framework.RunOptions,
    scenario: *const framework.Scenario,
    comptime body: fn (ctx: *Ctx) anyerror!void,
) !void {
    var counting: framework.CountingAllocator = .init(allocator);
    var ctx: Ctx = .{ .buf = undefined };

    if (opts.smoke) {
        try framework.smokeScenario(io, allocator, scenario, &counting, Ctx, &ctx, body);
        return;
    }
    try framework.driveScenario(io, allocator, opts, scenario, &counting, Ctx, &ctx, body);
}

fn runEncodeVarint1byte(
    io: std.Io,
    allocator: std.mem.Allocator,
    opts: framework.RunOptions,
    scenario: *const framework.Scenario,
) !void {
    try runEncodeScenario(io, allocator, opts, scenario, encodeVarintU64Body1);
}

fn runEncodeVarint10byte(
    io: std.Io,
    allocator: std.mem.Allocator,
    opts: framework.RunOptions,
    scenario: *const framework.Scenario,
) !void {
    try runEncodeScenario(io, allocator, opts, scenario, encodeVarintU64BodyMax);
}

fn runEncodeFixed32(
    io: std.Io,
    allocator: std.mem.Allocator,
    opts: framework.RunOptions,
    scenario: *const framework.Scenario,
) !void {
    try runEncodeScenario(io, allocator, opts, scenario, encodeFixed32Body);
}

fn runEncodeFixed64(
    io: std.Io,
    allocator: std.mem.Allocator,
    opts: framework.RunOptions,
    scenario: *const framework.Scenario,
) !void {
    try runEncodeScenario(io, allocator, opts, scenario, encodeFixed64Body);
}

pub const all = [_]framework.Scenario{
    .{
        .id = "encode-varint-1byte",
        .layer = .micro,
        .zero_alloc_expected = true,
        .default_iterations = 1_000_000,
        .input_bytes = 8,
        .run = runEncodeVarint1byte,
    },
    .{
        .id = "encode-varint-10byte",
        .layer = .micro,
        .zero_alloc_expected = true,
        .default_iterations = 1_000_000,
        .input_bytes = 8,
        .run = runEncodeVarint10byte,
    },
    .{
        .id = "encode-fixed32",
        .layer = .micro,
        .zero_alloc_expected = true,
        .default_iterations = 1_000_000,
        .input_bytes = 4,
        .run = runEncodeFixed32,
    },
    .{
        .id = "encode-fixed64",
        .layer = .micro,
        .zero_alloc_expected = true,
        .default_iterations = 1_000_000,
        .input_bytes = 8,
        .run = runEncodeFixed64,
    },
};
