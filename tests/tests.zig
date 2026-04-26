const std = @import("std");
const protobuf = @import("protobuf");
const tests = @import("./generated/tests.pb.zig");
const DefaultValues = @import("./generated/jspb/test.pb.zig").DefaultValues;
const tests_oneof = @import("./generated/tests/oneof.pb.zig");
const metrics = @import("./generated/opentelemetry/proto/metrics/v1.pb.zig");
const selfref = @import("./generated/selfref.pb.zig");
const pblogs = @import("./generated/opentelemetry/proto/logs/v1.pb.zig");

test "DefaultValuesInit" {
    var demo: DefaultValues = .{};
    defer demo.deinit(std.testing.allocator);

    try std.testing.expectEqualSlices(u8, "default<>'\"abc", demo.string_field.?);
    try std.testing.expectEqual(true, demo.bool_field.?);
    try std.testing.expectEqual(demo.int_field, 11);
    try std.testing.expectEqual(demo.enum_field.?, .E1);
    try std.testing.expectEqualSlices(u8, "", demo.empty_field.?);
    try std.testing.expectEqualSlices(u8, "moo", demo.bytes_field.?);
}

test "DefaultValuesDecode" {
    var reader: std.Io.Reader = .fixed("");
    var demo = try DefaultValues.decode(&reader, std.testing.allocator);
    defer demo.deinit(std.testing.allocator);

    try std.testing.expectEqualSlices(u8, "default<>'\"abc", demo.string_field.?);
    try std.testing.expectEqual(true, demo.bool_field.?);
    try std.testing.expectEqual(demo.int_field, 11);
    try std.testing.expectEqual(demo.enum_field.?, .E1);
    try std.testing.expectEqualSlices(u8, "", demo.empty_field.?);
    try std.testing.expectEqualSlices(u8, "moo", demo.bytes_field.?);
}

test "issue #74" {
    var item: metrics.MetricsData = .{};
    var copy = try item.dupe(std.testing.allocator);
    copy.deinit(std.testing.allocator);
    item.deinit(std.testing.allocator);
}

test "LogsData proto issue #84" {
    var logsData: pblogs.LogsData = .{};
    defer logsData.deinit(std.testing.allocator);

    var rl: pblogs.ResourceLogs = .{};
    defer rl.deinit(std.testing.allocator);

    try logsData.resource_logs.append(std.testing.allocator, rl);

    var w: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer w.deinit();

    try logsData.encode(&w.writer, std.testing.allocator); // <- compile error before
}

const SelfRefNode = selfref.SelfRefNode;

test "self ref test" {
    var demo: SelfRefNode = .{};
    const demo2 = try std.testing.allocator.create(SelfRefNode);
    demo2.* = .{};
    demo2.version = 1;
    demo.node = demo2;
    defer demo.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(i32, 0), demo.version);

    var w: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer w.deinit();

    try demo.encode(&w.writer, std.testing.allocator);

    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x12, 0x02, 0x08, 0x01 }, w.written());

    var reader: std.Io.Reader = .fixed(w.written());
    var decoded = try SelfRefNode.decode(&reader, std.testing.allocator);
    defer decoded.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(i32, 1), decoded.node.?.version);
}

test "decode hardening: max_decode_depth rejects deeply-nested submessages" {
    // Encode a SelfRefNode chain: version=1 wrapped in N nested `node`
    // submessages. Each wrap prepends `[tag=0x12, varint(inner_len)]`
    // bytes, where 0x12 is field 2 wire-type len. With max_decode_depth
    // = 100, going to depth 200 must be rejected before stack overflow.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    // innermost: version=1 → tag 0x08 (field 1 varint) + value 1
    try buf.appendSlice(std.testing.allocator, &.{ 0x08, 0x01 });

    var i: usize = 0;
    while (i < 200) : (i += 1) {
        const inner_len = buf.items.len;
        // Fits in a single varint byte for any inner_len < 128, otherwise
        // emit a 2-byte varint. Stays compact for the depth we need.
        if (inner_len < 128) {
            try buf.insertSlice(
                std.testing.allocator,
                0,
                &.{ 0x12, @intCast(inner_len) },
            );
        } else {
            const lo: u8 = @intCast((inner_len & 0x7F) | 0x80);
            const hi: u8 = @intCast(inner_len >> 7);
            try buf.insertSlice(
                std.testing.allocator,
                0,
                &.{ 0x12, lo, hi },
            );
        }
    }

    var reader: std.Io.Reader = .fixed(buf.items);
    try std.testing.expectError(
        error.InvalidInput,
        SelfRefNode.decode(&reader, std.testing.allocator),
    );
}

test "decode hardening: max_decode_alloc_per_field rejects huge string len" {
    // Encode jspb.DefaultValues string_field (field 1) with a length
    // prefix of 32 MiB — exceeds protobuf.wire.max_decode_alloc_per_field
    // (16 MiB). The decoder must error before any allocation occurs, so
    // we don't need to provide the 32 MiB body.
    const big: u64 = 32 * 1024 * 1024;
    // varint(big): encode 5 bytes worth — big < 2^28 so 4 bytes suffice
    var buf: [16]u8 = undefined;
    var n: usize = 0;
    buf[n] = 0x0A; // tag = (1 << 3) | 2 (len)
    n += 1;
    var v = big;
    while (v >= 0x80) : (v >>= 7) {
        buf[n] = @as(u8, @intCast(v & 0x7F)) | 0x80;
        n += 1;
    }
    buf[n] = @as(u8, @intCast(v));
    n += 1;

    var reader: std.Io.Reader = .fixed(buf[0..n]);
    try std.testing.expectError(
        error.InvalidInput,
        DefaultValues.decode(&reader, std.testing.allocator),
    );
}

// TODO: check for cyclic structure
