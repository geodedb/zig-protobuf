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

test "dupe hardening: max_dupe_depth rejects deep chain" {
    // Build a SelfRefNode chain longer than protobuf.max_dupe_depth (100).
    // Cycles or pathological depth would otherwise infinite-recurse on
    // dupe. Allocations live in an arena so partial-clone state on the
    // OutOfMemory failure path is reclaimed deterministically.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const ally = arena.allocator();

    var head: SelfRefNode = .{};
    var current: *SelfRefNode = &head;
    var i: u32 = 0;
    while (i < 200) : (i += 1) {
        const node = try ally.create(SelfRefNode);
        node.* = .{};
        node.version = @intCast(i + 1);
        current.node = node;
        current = node;
    }

    try std.testing.expectError(error.OutOfMemory, head.dupe(ally));
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

test "decode hardening: negative length prefix on packed repeated rejected" {
    // Packed repeated int32 field (Packed.int32_list = field 1, wire-type
    // len → tag 0x0A) with a length prefix that decodes as int32 == -1
    // (the five-byte sequence FF FF FF FF 0F). Must return InvalidInput,
    // not panic on @intCast(-1) → usize.
    const Packed = tests.Packed;
    const buf = [_]u8{ 0x0A, 0xFF, 0xFF, 0xFF, 0xFF, 0x0F };
    var reader: std.Io.Reader = .fixed(buf[0..]);
    try std.testing.expectError(
        error.InvalidInput,
        Packed.decode(&reader, std.testing.allocator),
    );
}

test "decode hardening: negative length prefix on unpacked repeated rejected" {
    // UnPacked.int32_list (field 1) sent with wire-type len (tag 0x0A) and
    // a length prefix decoding to int32 == -1. The .repeated branch must
    // reject before @intCast(len).
    const UnPacked = tests.UnPacked;
    const buf = [_]u8{ 0x0A, 0xFF, 0xFF, 0xFF, 0xFF, 0x0F };
    var reader: std.Io.Reader = .fixed(buf[0..]);
    try std.testing.expectError(
        error.InvalidInput,
        UnPacked.decode(&reader, std.testing.allocator),
    );
}

test "decode hardening: deeply-nested unknown groups rejected" {
    // An unknown field with sgroup wire-type repeated deeper than
    // max_decode_depth (100) with no matching egroup must return
    // InvalidInput rather than recursing to stack exhaustion (CWE-674).
    // We decode into SelfRefNode, whose fields are 1 (version) and 2
    // (node); field 3 is unknown, so tag 0x1B (field 3, wire sgroup)
    // routes through skipField, which recurses for each nested sgroup.
    // (Fields 1/2 would hit the known-field wire-type-mismatch guard and
    // never reach skipField, so an unknown field number is required to
    // exercise the recursive path.)
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    var i: usize = 0;
    while (i < 150) : (i += 1) {
        try buf.append(std.testing.allocator, 0x1B); // field 3, wire sgroup
    }
    var reader: std.Io.Reader = .fixed(buf.items);
    try std.testing.expectError(
        error.InvalidInput,
        SelfRefNode.decode(&reader, std.testing.allocator),
    );
}

// TODO: check for cyclic structure

test "decode: packed enum list with multi-byte values round-trips" {
    // Packed enum list (Packed.enum_list = field 10, packed). Encode three
    // enum values requiring multi-byte varints and confirm decode yields
    // exactly three elements (correctness across 1/2/3-byte varints).
    var src: tests.Packed = .{};
    defer src.deinit(std.testing.allocator);
    try src.enum_list.append(std.testing.allocator, @enumFromInt(300)); // 2-byte varint
    try src.enum_list.append(std.testing.allocator, @enumFromInt(70000)); // 3-byte varint
    try src.enum_list.append(std.testing.allocator, @enumFromInt(4)); // 1-byte

    var w: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer w.deinit();
    try src.encode(&w.writer, std.testing.allocator);

    var reader: std.Io.Reader = .fixed(w.written());
    var decoded = try tests.Packed.decode(&reader, std.testing.allocator);
    defer decoded.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), decoded.enum_list.items.len);
    try std.testing.expectEqual(@as(i32, 300), @intFromEnum(decoded.enum_list.items[0]));
    try std.testing.expectEqual(@as(i32, 70000), @intFromEnum(decoded.enum_list.items[1]));
    try std.testing.expectEqual(@as(i32, 4), @intFromEnum(decoded.enum_list.items[2]));
}

test "decode: packed enum reservation is capped on loose varint payloads" {
    // Regression for P-2026-02: the packed enum path reserves one slot per
    // wire *byte*, but enums are 1-10 byte varints. A byte-heavy payload
    // (each value a 5-byte varint) must NOT eagerly reserve `bytes` slots;
    // the up-front reservation is capped at max_decode_reserve_elements and
    // ArrayList amortized growth covers the rest. We assert the final
    // capacity tracks the element count, staying far below the wire byte
    // count (which the unfixed code would have reserved up front).
    // n is well below max_decode_elements (1M) so this exercises the
    // reservation cap, not the element cap — n*5 bytes (500k) stays clear of
    // the per-record byte guard regardless of future constant tweaks.
    const n: usize = 100_000;
    var src: tests.Packed = .{};
    defer src.deinit(std.testing.allocator);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        try src.enum_list.append(std.testing.allocator, @enumFromInt(2_000_000_000)); // 5-byte varint
    }

    var w: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer w.deinit();
    try src.encode(&w.writer, std.testing.allocator);

    var reader: std.Io.Reader = .fixed(w.written());
    var decoded = try tests.Packed.decode(&reader, std.testing.allocator);
    defer decoded.deinit(std.testing.allocator);

    // Payload is ~5x the element count; capacity must stay proportional to
    // the element count, not the byte count. A small constant slack over
    // `n` confirms the eager reservation did not balloon to `bytes`.
    try std.testing.expectEqual(n, decoded.enum_list.items.len);
    try std.testing.expect(decoded.enum_list.capacity < 2 * n);
    try std.testing.expect(decoded.enum_list.capacity < w.written().len);
}

test "decode hardening: packed scalar cumulative element cap across records" {
    // A packed repeated field may legally be split across multiple wire
    // records that concatenate into one list. The cumulative element cap
    // (max_decode_elements = 1M) must hold ACROSS records, not just per
    // record: the per-record pre-loop guard only bounds a single record,
    // so the in-loop accumulator check is the sole defense against
    // cross-record growth (CWE-789). Encode one record of 600k single-byte
    // int32 values, then decode two copies back-to-back (1.2M > 1M).
    var src: tests.Packed = .{};
    defer src.deinit(std.testing.allocator);
    var i: usize = 0;
    while (i < 600_000) : (i += 1) {
        try src.int32_list.append(std.testing.allocator, @intCast(i % 128));
    }

    var w: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer w.deinit();
    try src.encode(&w.writer, std.testing.allocator);

    // Two packed records for field 1 back-to-back.
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(std.testing.allocator);
    try input.appendSlice(std.testing.allocator, w.written());
    try input.appendSlice(std.testing.allocator, w.written());

    var reader: std.Io.Reader = .fixed(input.items);
    try std.testing.expectError(
        error.InvalidInput,
        tests.Packed.decode(&reader, std.testing.allocator),
    );
}

test "decode hardening: packed enum cumulative element cap across records" {
    // Mirror of the packed-scalar cross-record test for the packed ENUM
    // path: a packed repeated enum may also be split across multiple wire
    // records that concatenate into one list, so the in-loop accumulator
    // check is the sole defense against cross-record growth (CWE-789).
    // Encode one record of 600k single-byte enum values (SE_ZERO = 0
    // encodes as a 1-byte varint), then decode two copies back-to-back
    // (1.2M > max_decode_elements = 1M). The error must fire mid-loop on
    // the second record without leaking the ~600k already-committed
    // elements or crashing in the error-cleanup path.
    var src: tests.Packed = .{};
    defer src.deinit(std.testing.allocator);
    var i: usize = 0;
    while (i < 600_000) : (i += 1) {
        try src.enum_list.append(std.testing.allocator, .SE_ZERO);
    }

    var w: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer w.deinit();
    try src.encode(&w.writer, std.testing.allocator);

    // Two packed records for field 10 (enum_list) back-to-back.
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(std.testing.allocator);
    try input.appendSlice(std.testing.allocator, w.written());
    try input.appendSlice(std.testing.allocator, w.written());

    var reader: std.Io.Reader = .fixed(input.items);
    try std.testing.expectError(
        error.InvalidInput,
        tests.Packed.decode(&reader, std.testing.allocator),
    );
}

test "decode hardening: error mid-list frees committed repeated-string elements" {
    // Regression for the latent crash/leak in decodeRepeated's error
    // cleanup. WithRepeatedStrings.name is `repeated string` (field 1),
    // so decodeMessage calls decodeRepeated once per element — the Nth
    // call enters with N-1 committed elements AND grown capacity
    // (capacity > items). Encode several valid elements, then one element
    // whose length prefix exceeds max_decode_alloc_per_field (16 MiB), so
    // the decoder errors BEFORE allocating the huge body. The cleanup
    // path must (a) not crash (the old shrinkAndFree(current_capacity)
    // asserted new_len <= items.len and panicked on the capacity slack),
    // and (b) free the already-committed string elements so the abandoned
    // result leaks nothing (testing.allocator catches both).
    const WithRepeatedStrings = tests.WithRepeatedStrings;

    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(std.testing.allocator);

    // Eight valid 3-byte string elements: tag 0x0A, len 0x03, "abc".
    var k: usize = 0;
    while (k < 8) : (k += 1) {
        try input.appendSlice(
            std.testing.allocator,
            &.{ 0x0A, 0x03, 'a', 'b', 'c' },
        );
    }
    // Ninth element: tag 0x0A, then a varint length of 32 MiB (> 16 MiB
    // cap) — rejected before the body is allocated.
    try input.append(std.testing.allocator, 0x0A);
    const big: u64 = 32 * 1024 * 1024;
    var v = big;
    while (v >= 0x80) : (v >>= 7) {
        try input.append(
            std.testing.allocator,
            @as(u8, @intCast(v & 0x7F)) | 0x80,
        );
    }
    try input.append(std.testing.allocator, @as(u8, @intCast(v)));

    var reader: std.Io.Reader = .fixed(input.items);
    try std.testing.expectError(
        error.InvalidInput,
        WithRepeatedStrings.decode(&reader, std.testing.allocator),
    );
}

test "decode hardening: error mid-list frees committed repeated-SUBMESSAGE elements" {
    // Direct regression for the .submessage arm of decodeRepeated's
    // function-entry errdefer (the `for (result.items) |*item|
    // item.deinit(allocator);` branch). LogsData.resource_logs is
    // `repeated ResourceLogs` (field 1, tag 0x0A), so decodeMessage calls
    // decodeRepeated once per element; each committed ResourceLogs owns a
    // heap `schema_url` string (field 3, tag 0x1A, an owned []const u8 when
    // decoded). When a later element errors mid-list, protobuf.decode
    // abandons the partial result WITHOUT deiniting it, so this errdefer
    // owns freeing every previously-committed submessage element (its
    // schema_url string AND the list backing buffer). The packed
    // scalar/enum arms and the unpacked-string arm already have direct
    // tests; this exercises the submessage arm so any future
    // leak/double-free/crash there is caught by testing.allocator.
    //
    // Construction: encode a real LogsData with 4 valid ResourceLogs (each
    // schema_url = a heap-dup'd string, so the SOURCE deinit frees them
    // legitimately and encode merely copies the bytes), capture its wire
    // bytes as a valid prefix, then append one hand-built outer record
    // {0x0A, outer_len, 0x1A, varint(32 MiB)} whose inner schema_url length
    // prefix exceeds max_decode_alloc_per_field (16 MiB). The inner string
    // decode rejects that length BEFORE allocating the body, so the decode
    // errors with InvalidInput while 4 elements are already committed.
    const n: usize = 4;

    // Build the valid prefix from a real, correctly-owned LogsData value.
    var src: pblogs.LogsData = .{};
    defer src.deinit(std.testing.allocator);
    {
        var i: usize = 0;
        while (i < n) : (i += 1) {
            // Heap-dup the schema_url so src.deinit frees it correctly
            // (a string literal would make deinit free a non-heap pointer).
            const url = try std.testing.allocator.dupe(u8, "https://example.test/schema");
            errdefer std.testing.allocator.free(url);
            try src.resource_logs.append(
                std.testing.allocator,
                .{ .schema_url = url },
            );
        }
    }

    var prefix: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer prefix.deinit();
    try src.encode(&prefix.writer, std.testing.allocator);

    // Sanity: the valid prefix alone decodes successfully into n elements,
    // each owning its schema_url, and round-trips leak-free.
    {
        var ok_reader: std.Io.Reader = .fixed(prefix.written());
        var ok = try pblogs.LogsData.decode(&ok_reader, std.testing.allocator);
        defer ok.deinit(std.testing.allocator);
        try std.testing.expectEqual(n, ok.resource_logs.items.len);
        try std.testing.expectEqualSlices(
            u8,
            "https://example.test/schema",
            ok.resource_logs.items[0].schema_url,
        );
    }

    // Build the erroring outer record: an outer LogsData.resource_logs
    // element (tag 0x0A) whose body is a ResourceLogs carrying schema_url
    // (tag 0x1A) with a length prefix of 32 MiB (> 16 MiB cap). The inner
    // body bytes {0x1A, varint(32 MiB)} are the outer record's payload.
    var inner: std.ArrayList(u8) = .empty;
    defer inner.deinit(std.testing.allocator);
    try inner.append(std.testing.allocator, 0x1A); // field 3 (schema_url), wire len
    const big: u64 = 32 * 1024 * 1024;
    var v = big;
    while (v >= 0x80) : (v >>= 7) {
        try inner.append(
            std.testing.allocator,
            @as(u8, @intCast(v & 0x7F)) | 0x80,
        );
    }
    try inner.append(std.testing.allocator, @as(u8, @intCast(v)));

    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(std.testing.allocator);
    // Valid prefix: 4 committed ResourceLogs elements.
    try input.appendSlice(std.testing.allocator, prefix.written());
    // Erroring outer record: tag 0x0A, then the inner body length as a
    // varint, then the inner body. inner.items.len is small (< 128) so its
    // length is a single varint byte.
    try input.append(std.testing.allocator, 0x0A); // field 1, wire len
    std.debug.assert(inner.items.len < 0x80);
    try input.append(std.testing.allocator, @as(u8, @intCast(inner.items.len)));
    try input.appendSlice(std.testing.allocator, inner.items);

    var reader: std.Io.Reader = .fixed(input.items);
    try std.testing.expectError(
        error.InvalidInput,
        pblogs.LogsData.decode(&reader, std.testing.allocator),
    );
}
