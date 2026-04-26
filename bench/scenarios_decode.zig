//! Micro decode scenarios — the wire-level decoding hot paths.
//!
//! Inputs are deterministic byte literals so the workload is identical
//! across runs and platforms. Every scenario carries a zero-alloc
//! contract: `decodeScalar` and `Tag.decode` both work against a
//! `std.Io.Reader.fixed` buffer and never touch the allocator.
//!
//! Each scenario is a `framework.Scenario` value referenced from the
//! main bench-binary registry.

const std = @import("std");
const protobuf = @import("protobuf");
const wire = protobuf.wire;
const framework = @import("framework.zig");

const sink = framework.sink;

const Ctx = struct { input: []const u8 };

fn decodeVarintU64Body(ctx: *Ctx) !void {
    var reader: std.Io.Reader = .fixed(ctx.input);
    const v: u64, const consumed = try wire.decodeScalar(.uint64, &reader);
    sink(u64, v);
    sink(usize, consumed);
}

fn decodeVarintI64Body(ctx: *Ctx) !void {
    var reader: std.Io.Reader = .fixed(ctx.input);
    const v: i64, const consumed = try wire.decodeScalar(.int64, &reader);
    sink(i64, v);
    sink(usize, consumed);
}

fn decodeVarintI32Body(ctx: *Ctx) !void {
    var reader: std.Io.Reader = .fixed(ctx.input);
    const v: i32, const consumed = try wire.decodeScalar(.int32, &reader);
    sink(i32, v);
    sink(usize, consumed);
}

fn decodeFixed32Body(ctx: *Ctx) !void {
    var reader: std.Io.Reader = .fixed(ctx.input);
    const v: f32, const consumed = try wire.decodeScalar(.float, &reader);
    sink(f32, v);
    sink(usize, consumed);
}

fn decodeFixed64Body(ctx: *Ctx) !void {
    var reader: std.Io.Reader = .fixed(ctx.input);
    const v: f64, const consumed = try wire.decodeScalar(.double, &reader);
    sink(f64, v);
    sink(usize, consumed);
}

fn decodeTagBody(ctx: *Ctx) !void {
    var reader: std.Io.Reader = .fixed(ctx.input);
    const tag: wire.Tag, const consumed = try wire.Tag.decode(&reader);
    sink(wire.Tag, tag);
    sink(usize, consumed);
}

fn runDecodeScenario(
    io: std.Io,
    allocator: std.mem.Allocator,
    opts: framework.RunOptions,
    scenario: *const framework.Scenario,
    input: []const u8,
    comptime body: fn (ctx: *Ctx) anyerror!void,
) !void {
    var counting: framework.CountingAllocator = .init(allocator);
    var ctx: Ctx = .{ .input = input };

    if (opts.smoke) {
        try framework.smokeScenario(io, allocator, scenario, &counting, Ctx, &ctx, body);
        return;
    }
    try framework.driveScenario(io, allocator, opts, scenario, &counting, Ctx, &ctx, body);
}

fn runDecodeVarint1byte(
    io: std.Io,
    allocator: std.mem.Allocator,
    opts: framework.RunOptions,
    scenario: *const framework.Scenario,
) !void {
    const input: []const u8 = &.{0x01};
    try runDecodeScenario(io, allocator, opts, scenario, input, decodeVarintU64Body);
}

fn runDecodeVarint2byte(
    io: std.Io,
    allocator: std.mem.Allocator,
    opts: framework.RunOptions,
    scenario: *const framework.Scenario,
) !void {
    const input: []const u8 = &.{ 0xAC, 0x02 };
    try runDecodeScenario(io, allocator, opts, scenario, input, decodeVarintU64Body);
}

fn runDecodeVarint5byteI32(
    io: std.Io,
    allocator: std.mem.Allocator,
    opts: framework.RunOptions,
    scenario: *const framework.Scenario,
) !void {
    const input: []const u8 = &.{ 0xFF, 0xFF, 0xFF, 0xFF, 0x0F };
    try runDecodeScenario(io, allocator, opts, scenario, input, decodeVarintI32Body);
}

fn runDecodeVarint10byteI64(
    io: std.Io,
    allocator: std.mem.Allocator,
    opts: framework.RunOptions,
    scenario: *const framework.Scenario,
) !void {
    const input: []const u8 = &.{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01 };
    try runDecodeScenario(io, allocator, opts, scenario, input, decodeVarintI64Body);
}

fn runDecodeFixed32(
    io: std.Io,
    allocator: std.mem.Allocator,
    opts: framework.RunOptions,
    scenario: *const framework.Scenario,
) !void {
    const input: []const u8 = &.{ 0x00, 0x00, 0x80, 0x3F };
    try runDecodeScenario(io, allocator, opts, scenario, input, decodeFixed32Body);
}

fn runDecodeFixed64(
    io: std.Io,
    allocator: std.mem.Allocator,
    opts: framework.RunOptions,
    scenario: *const framework.Scenario,
) !void {
    const input: []const u8 = &.{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF0, 0x3F };
    try runDecodeScenario(io, allocator, opts, scenario, input, decodeFixed64Body);
}

fn runDecodeTag(
    io: std.Io,
    allocator: std.mem.Allocator,
    opts: framework.RunOptions,
    scenario: *const framework.Scenario,
) !void {
    const input: []const u8 = &.{0x08};
    try runDecodeScenario(io, allocator, opts, scenario, input, decodeTagBody);
}

pub const all = [_]framework.Scenario{
    .{
        .id = "decode-varint-1byte",
        .layer = .micro,
        .zero_alloc_expected = true,
        .default_iterations = 1_000_000,
        .input_bytes = 1,
        .run = runDecodeVarint1byte,
    },
    .{
        .id = "decode-varint-2byte",
        .layer = .micro,
        .zero_alloc_expected = true,
        .default_iterations = 1_000_000,
        .input_bytes = 2,
        .run = runDecodeVarint2byte,
    },
    .{
        .id = "decode-varint-5byte-i32",
        .layer = .micro,
        .zero_alloc_expected = true,
        .default_iterations = 1_000_000,
        .input_bytes = 5,
        .run = runDecodeVarint5byteI32,
    },
    .{
        .id = "decode-varint-10byte-i64",
        .layer = .micro,
        .zero_alloc_expected = true,
        .default_iterations = 1_000_000,
        .input_bytes = 10,
        .run = runDecodeVarint10byteI64,
    },
    .{
        .id = "decode-fixed32",
        .layer = .micro,
        .zero_alloc_expected = true,
        .default_iterations = 1_000_000,
        .input_bytes = 4,
        .run = runDecodeFixed32,
    },
    .{
        .id = "decode-fixed64",
        .layer = .micro,
        .zero_alloc_expected = true,
        .default_iterations = 1_000_000,
        .input_bytes = 8,
        .run = runDecodeFixed64,
    },
    .{
        .id = "decode-tag",
        .layer = .micro,
        .zero_alloc_expected = true,
        .default_iterations = 1_000_000,
        .input_bytes = 1,
        .run = runDecodeTag,
    },
};
