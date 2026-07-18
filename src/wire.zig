//! Protocol Buffers definitions and functions for wire encoding/decoding.
const std = @import("std");

const protobuf = @import("protobuf.zig");
const builtin = @import("builtin");
const build_options = @import("build_options");

/// Compile-time switch for the P-02 fast-path varint decoder. When
/// false, `decodeScalar` for variable-width types falls back to the
/// pure byte-at-a-time loop (the slow path that lived here before
/// the optimization). The AB runner toggles this via
/// `-Duse-fast-varint=false` for the disabled run; see
/// docs/performance/2026-04-26-encode-decode-baseline/architecture.md
/// §9 ("A/B feature-flag contract").
pub const use_fast_varint: bool = build_options.use_fast_varint;

/// Compile-time switch for the P-05 packed-decode `ensureTotalCapacity`
/// preallocation. When true (the default), `decodeRepeated`'s packed
/// branches reserve list capacity once based on the length-prefix
/// before entering the per-element loop, eliminating per-element
/// reallocs. When false, each `append` may grow the list, which is
/// the original quadratic-realloc behavior. AB-disable via
/// `-Duse-ensure-capacity-packed=false`.
pub const use_ensure_capacity_packed: bool = build_options.use_ensure_capacity_packed;
const log = if (builtin.os.tag != .freestanding) std.log.scoped(.zig_protobuf) else struct {
    // no-op log implementation for freestanding targets
    pub fn debug(
        comptime _: []const u8,
        _: anytype,
    ) void {}
};

/// Error type for decode operations.
pub const DecodeError = error{
    InvalidInput,
    EndOfStream,
    ReadFailed,
    OutOfMemory,
};

/// Maximum nested-submessage depth allowed by `decodeMessage`. Crafted
/// inputs with deeper nesting return `error.InvalidInput` before the
/// recursion can exhaust the thread stack (CWE-674).
pub const max_decode_depth: u32 = 100;

/// Maximum bytes a single length-prefix may demand from the allocator
/// when decoding a `string`, `bytes`, or repeated-string element.
/// Larger values return `error.InvalidInput` before the allocation
/// occurs (CWE-789).
pub const max_decode_alloc_per_field: usize = 16 * 1024 * 1024;

/// Maximum number of elements in a single repeated/packed list. Larger
/// values return `error.InvalidInput` to prevent element-count
/// amplification attacks where a small input drives unbounded
/// `ArrayListUnmanaged` growth (CWE-789).
pub const max_decode_elements: usize = 1_000_000;

/// Upper bound on how many elements we eagerly reserve for a packed list
/// before falling back to ArrayList's amortized growth. Bounds worst-case
/// over-reservation when a wire byte count is a loose upper bound on the
/// element count (multi-byte varint scalars/enums encode 1-10 bytes each,
/// so `bytes` can be up to 10x the true count). Decoding still succeeds for
/// larger lists; only the up-front reservation is capped.
pub const max_decode_reserve_elements: usize = 64 * 1024;

/// Wire type.
pub const Type = enum(u3) {
    /// int32, int64, uint32, uint64, sint32, sint64, bool, enum
    varint = 0,
    /// fixed64, sfixed64, double - referred to as `i64` in protobuf docs
    fixed64 = 1,
    /// string, bytes, embedded messages, packed repeated fields
    len = 2,
    /// group start (deprecated)
    sgroup = 3,
    /// group end (deprecated)
    egroup = 4,
    /// fixed32, sfixed32, float - referred to as `i32` in protobuf docs
    fixed32 = 5,
};

/// Record tag.
pub const Tag = packed struct(u32) {
    /// Wire type.
    wire_type: Type,
    /// Field number.
    field: u29,

    /// Encode tag to byte stream. Returns number of bytes used for encoding,
    /// which is guaranteed to be between 1-5 inclusive.
    pub inline fn encode(
        comptime self: Tag,
        writer: anytype,
    ) !usize {
        const out_bytes: []const u8 = comptime b: {
            var raw: u32 = @bitCast(self);
            var buf: [5]u8 = undefined;
            const len: u3 = for (0..5) |i| {
                if (raw < 0x80) {
                    buf[i] = @intCast(raw);
                    break i + 1;
                } else {
                    buf[i] = 0x80 | @as(u8, @intCast(raw & 0x7F));
                }
                raw >>= 7;
            } else unreachable;

            break :b std.fmt.comptimePrint("{s}", .{buf[0..len]});
        };
        try writer.writeAll(out_bytes);
        return out_bytes.len;
    }

    test encode {
        const tag: Tag = .{ .wire_type = .len, .field = 15 };

        var result: [2]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&result);

        const encoded = try tag.encode(&writer);

        try std.testing.expectEqual(1, encoded);
        try std.testing.expectEqual((15 << 3) | 2, result[0]);

        writer = .fixed(&result);
        const tag2: Tag = .{ .wire_type = .fixed64, .field = 1 };
        const encoded2 = try tag2.encode(&writer);
        try std.testing.expectEqual(1, encoded2);
        try std.testing.expectEqual((1 << 3) | 1, result[0]);
    }

    /// Decode from byte stream to tag. Unlike normal `varint` types, the
    /// encoding for a tag is guaranteed not to use ZigZag encoding, as the
    /// tag will always be unsigned.
    pub fn decode(reader: anytype) DecodeError!struct {
        /// Decoded tag.
        Tag,
        /// Number of bytes consumed from reader.
        usize,
    } {
        const raw_result: u32, const consumed: usize =
            try decodeScalar(.uint32, reader);

        const invalid_wire_type = (raw_result & 0x7) > 5;
        if (invalid_wire_type) {
            @branchHint(.cold);
            return error.InvalidInput;
        }

        // Field number 0 is forbidden by the protobuf spec (the smallest
        // valid field number is 1). Rejecting it here prevents malformed
        // payloads from masquerading as legitimate tags downstream.
        if ((raw_result >> 3) == 0) {
            @branchHint(.cold);
            return error.InvalidInput;
        }

        return .{ @bitCast(raw_result), consumed };
    }

    test decode {
        const bytes: []const u8 = &.{ 0xFD, 0xFF, 0xFF, 0xFF, 0x0F };
        var reader: std.Io.Reader = .fixed(bytes);
        const tag: Tag, const consumed = try decode(&reader);

        try std.testing.expectEqual(5, consumed);
        try std.testing.expectEqual(.fixed32, tag.wire_type);
        try std.testing.expectEqual(0x1FFFFFFF, tag.field);
    }
};

/// ZigZag transform for `sint32`/`sint64` proto fields. Maps signed
/// integers onto unsigned values so that small-magnitude negatives
/// encode as short varints. See protobuf.dev/programming-guides/encoding
/// for the canonical mapping table.
pub const ZigZag = struct {
    /// ZigZag-encode an `i32` or `i64` value into the unsigned space
    /// suitable for varint encoding.
    pub fn encode(int_value: anytype) u64 {
        const type_of_val = @TypeOf(int_value);
        const to_int64: i64 = switch (type_of_val) {
            i32 => @intCast(int_value),
            i64 => int_value,
            else => @compileError("should not be here"),
        };
        const calc = (to_int64 << 1) ^ (to_int64 >> 63);
        return @bitCast(calc);
    }

    test encode {
        try std.testing.expectEqual(@as(u64, 0), ZigZag.encode(@as(i32, 0)));
        try std.testing.expectEqual(@as(u64, 1), ZigZag.encode(@as(i32, -1)));
        try std.testing.expectEqual(@as(u64, 2), ZigZag.encode(@as(i32, 1)));
        try std.testing.expectEqual(
            @as(u64, 0xfffffffe),
            ZigZag.encode(@as(i32, std.math.maxInt(i32))),
        );
        try std.testing.expectEqual(
            @as(u64, 0xffffffff),
            ZigZag.encode(@as(i32, std.math.minInt(i32))),
        );

        try std.testing.expectEqual(@as(u64, 0), ZigZag.encode(@as(i64, 0)));
        try std.testing.expectEqual(@as(u64, 1), ZigZag.encode(@as(i64, -1)));
        try std.testing.expectEqual(@as(u64, 2), ZigZag.encode(@as(i64, 1)));
        try std.testing.expectEqual(
            @as(u64, 0xfffffffffffffffe),
            ZigZag.encode(@as(i64, std.math.maxInt(i64))),
        );
        try std.testing.expectEqual(
            @as(u64, 0xffffffffffffffff),
            ZigZag.encode(@as(i64, std.math.minInt(i64))),
        );
    }

    pub fn decode(raw_int: anytype) @TypeOf(raw_int) {
        const RawInt = @TypeOf(raw_int);
        comptime std.debug.assert(RawInt == i32 or RawInt == i64);

        const unsigned: if (RawInt == i32) u32 else u64 = @bitCast(raw_int);

        if (raw_int & 0x1 == 0) return @bitCast(unsigned >> 1);
        return @bitCast(
            (unsigned >> 1) ^ (comptime ~@as(@TypeOf(unsigned), 0)),
        );
    }

    test decode {
        try std.testing.expectEqual(0, ZigZag.decode(@as(i32, 0)));
        try std.testing.expectEqual(-1, ZigZag.decode(@as(i32, 1)));
        try std.testing.expectEqual(1, ZigZag.decode(@as(i32, 2)));
        try std.testing.expectEqual(
            std.math.maxInt(i32),
            ZigZag.decode(@as(i32, @bitCast(@as(u32, 0xfffffffe)))),
        );
        try std.testing.expectEqual(
            std.math.minInt(i32),
            ZigZag.decode(@as(i32, @bitCast(@as(u32, 0xffffffff)))),
        );
        try std.testing.expectEqual(-2, ZigZag.decode(@as(i32, 3)));
        try std.testing.expectEqual(-500, ZigZag.decode(@as(i32, 999)));

        try std.testing.expectEqual(0, ZigZag.decode(@as(i64, 0)));
        try std.testing.expectEqual(-1, ZigZag.decode(@as(i64, 1)));
        try std.testing.expectEqual(1, ZigZag.decode(@as(i64, 2)));
        try std.testing.expectEqual(
            std.math.maxInt(i64),
            ZigZag.decode(@as(i64, @bitCast(@as(u64, 0xfffffffffffffffe)))),
        );
        try std.testing.expectEqual(
            std.math.minInt(i64),
            ZigZag.decode(@as(i64, @bitCast(@as(u64, 0xffffffffffffffff)))),
        );
        try std.testing.expectEqual(-500, ZigZag.decode(@as(i64, 999)));
    }
};

/// Safely convert a decoded wire `int32` into an enum-typed field.
///
/// Proto3 enums are *open*: an unrecognized value on the wire is not an
/// error and must round-trip through decode/encode unchanged (see
/// `docs/GAP_ANALYSIS.md` R10). The code generator therefore always emits
/// enums as non-exhaustive (`enum(i32) { ..., _ }`), for which
/// `@enumFromInt` is defined for every `i32` — no runtime check needed,
/// no panic possible.
///
/// `decodeMessage`/`decodeRepeated` reach enum-typed fields generically via
/// comptime reflection, though, and nothing in the type system stops a
/// hand-authored struct (bypassing the generator) from declaring an
/// *exhaustive* enum. `@enumFromInt` on an exhaustive enum panics in safe
/// build modes (and is undefined behavior in `ReleaseFast`) for any wire
/// value that isn't a declared tag — an out-of-range value from untrusted
/// input becomes a process crash (CWE-704). Since an exhaustive enum has no
/// way to represent an unrecognized value, decoding fails closed with
/// `error.InvalidInput` in that case instead.
///
/// This performs no extra work for the (only currently generated)
/// non-exhaustive case: the `is_exhaustive` check is resolved entirely at
/// comptime, so the non-exhaustive branch compiles down to the original
/// unchecked `@enumFromInt`. (PB-2026-007)
inline fn enumFromWire(comptime T: type, raw: i32) DecodeError!T {
    const info = @typeInfo(T).@"enum";
    if (comptime !info.is_exhaustive) {
        return @enumFromInt(raw);
    }
    inline for (info.fields) |f| {
        if (raw == f.value) return @field(T, f.name);
    }
    return error.InvalidInput;
}

test enumFromWire {
    const NonExhaustive = enum(i32) { A = 0, B = 1, _ };
    const Exhaustive = enum(i32) { A = 0, B = 1 };

    var raw: i32 = 999999999;
    try std.testing.expectEqual(
        @as(i32, 999999999),
        @intFromEnum(try enumFromWire(NonExhaustive, raw)),
    );

    try std.testing.expectError(
        error.InvalidInput,
        enumFromWire(Exhaustive, raw),
    );

    raw = 1;
    try std.testing.expectEqual(.B, try enumFromWire(NonExhaustive, raw));
    try std.testing.expectEqual(.B, try enumFromWire(Exhaustive, raw));
}

/// Decode a non-slice scalar type from reader. Slice scalar types should be
/// decoded by directly reading a slice from the reader.
pub fn decodeScalar(
    comptime scalar: protobuf.FieldType.Scalar,
    reader: anytype,
) DecodeError!struct {
    /// Resulting decoded scalar.
    scalar.toType(),
    /// Number of bytes consumed from reader.
    usize,
} {
    comptime std.debug.assert(!scalar.isSlice());

    if (comptime scalar.isVariable()) {
        const Result = if (comptime scalar == .int32)
            i64
        else
            comptime scalar.toType();

        var val: Result = 0;
        const max_bytes: comptime_int = comptime b: {
            var byte_count: usize = 0;
            while (7 * byte_count < @bitSizeOf(Result)) {
                byte_count += 1;
            }

            // Valid negative values for `int32`, e.g. -1, may be sent in the
            // `int64` equivalent encoding.
            if (scalar == .int32) byte_count = 10;
            break :b byte_count;
        };

        // P-02 fast-path: when the next `max_bytes` are already
        // sitting in the reader's buffer, decode them inline without
        // per-byte `try takeByte()` error-return overhead. Single- and
        // two-byte varints are by far the hottest cases on real
        // protobuf payloads (small field numbers, small enums,
        // boolean flags), and the fast-path turns each into a
        // branchless few-instruction sequence.
        const consumed: usize = consumed: {
            if (comptime use_fast_varint) {
                const buffered = reader.buffered();
                if (buffered.len >= max_bytes) {
                    // Hot path: enough bytes in buffer to decode
                    // without any further reader interaction.
                    inline for (0..max_bytes) |i| {
                        const b = buffered[i];
                        const num = b & 0x7F;
                        val |= @as(Result, num) << @intCast(7 * i);
                        if (b >> 7 == 0) {
                            reader.toss(i + 1);
                            break :consumed i + 1;
                        }
                    } else {
                        // Tenth byte's high bit set on a 10-byte
                        // varint is malformed.
                        @branchHint(.cold);
                        return error.InvalidInput;
                    }
                }
                // Short-buffer fall-through: at least one byte must
                // come via takeByte; let the slow loop handle it.
            }

            break :consumed for (0..max_bytes) |i| {
                const b = try reader.takeByte();
                const num = b & 0x7F;
                val |= @as(Result, num) << @intCast(7 * i);
                if (b >> 7 == 0) break i + 1;
            } else {
                @branchHint(.cold);
                return error.InvalidInput;
            };
        };

        // As `int32` may receive `int64` equivalent encoding values, ensure
        // that values actually fit within `int32` range.
        if (comptime scalar == .int32) {
            // Encoded as `int32`
            if (val & @as(i64, @bitCast(@as(u64, 0xFFFFFFFF00000000))) == 0) {
                return .{ @truncate(val), consumed };
            }

            if (val < std.math.minInt(i32) or val > std.math.maxInt(i32)) {
                @branchHint(.cold);
                return error.InvalidInput;
            }

            return .{ @intCast(val), consumed };
        }

        if (comptime scalar.isZigZag()) {
            val = ZigZag.decode(val);
        }

        return .{ val, consumed };
    }

    if (comptime scalar.isFixed()) {
        const Unsigned = if (@bitSizeOf(scalar.toType()) == 32)
            u32
        else
            u64;

        var val: Unsigned = 0;
        for (0..@sizeOf(Unsigned)) |i| {
            const b = try reader.takeByte();
            val |= @as(Unsigned, b) << @intCast(8 * i);
        }
        return .{ @bitCast(val), @sizeOf(Unsigned) };
    }

    if (comptime scalar == .bool) {
        const b = try reader.takeByte();
        if (b == 0) {
            return .{ false, 1 };
        } else if (b == 1) {
            return .{ true, 1 };
        } else {
            @branchHint(.cold);
            return error.InvalidInput;
        }
    }
}

test decodeScalar {
    {
        const bytes: []const u8 = &.{ 0xFF, 0xFF, 0xFF, 0xFF, 0x0F };

        var reader: std.Io.Reader = .fixed(bytes);
        const decoded: u32, const consumed = try decodeScalar(.uint32, &reader);

        try std.testing.expectEqual(5, consumed);
        try std.testing.expectEqual(std.math.maxInt(u32), decoded);
    }

    {
        const bytes: []const u8 = &.{ 0xFF, 0xFF, 0xFF, 0xFF, 0x0F };
        var reader: std.Io.Reader = .fixed(bytes);

        const decoded: i32, const consumed = try decodeScalar(.sint32, &reader);

        try std.testing.expectEqual(5, consumed);
        try std.testing.expectEqual(std.math.minInt(i32), decoded);
    }

    { // Oversized `int32` value
        const bytes: []const u8 = &.{
            0xFF,
            0xFF,
            0xFF,
            0xFF,
            0xFF,
            0xFF,
            0xFF,
            0xFF,
            0x7F,
        };
        var reader: std.Io.Reader = .fixed(bytes);

        const max_u64 = decodeScalar(.int32, &reader);
        try std.testing.expectError(error.InvalidInput, max_u64);
    }

    { // Barely oversized `int32` value
        const bytes: []const u8 = &.{ 0xFF, 0xFF, 0xFF, 0xFF, 0x10 };
        var reader: std.Io.Reader = .fixed(bytes);

        const barely_too_big = decodeScalar(.int32, &reader);
        try std.testing.expectError(error.InvalidInput, barely_too_big);
    }

    { // Valid `int32` encoded as `int64`
        const bytes: []const u8 = &.{
            0xFF,
            0xFF,
            0xFF,
            0xFF,
            0xFF,
            0xFF,
            0xFF,
            0xFF,
            0xFF,
            0x01,
        };
        var reader: std.Io.Reader = .fixed(bytes);

        const decoded: i32, const consumed = try decodeScalar(.int32, &reader);
        try std.testing.expectEqual(10, consumed);
        try std.testing.expectEqual(-1, decoded);
    }

    { // Valid `int32` encoded as `int32`
        const bytes: []const u8 = &.{
            0xFF,
            0xFF,
            0xFF,
            0xFF,
            0x0F,
        };
        var reader: std.Io.Reader = .fixed(bytes);

        const decoded: i32, const consumed = try decodeScalar(.int32, &reader);
        try std.testing.expectEqual(5, consumed);
        try std.testing.expectEqual(-1, decoded);
    }
}

/// Decode a repeated field from reader. Return number of consumed bytes.
pub fn decodeRepeated(
    result: anytype,
    allocator: std.mem.Allocator,
    comptime field: protobuf.FieldType.Repeated,
    reader: anytype,
    options: struct {
        /// Number of bytes to parse. Provided for length-delimited records
        /// or packed repeated fields.
        bytes: ?usize = null,
        /// Internal: current submessage recursion depth, threaded through
        /// from `decodeMessage` so the depth limit is honored across
        /// repeated submessage boundaries.
        _depth: u32 = 0,
    },
) DecodeError!usize {
    comptime std.debug.assert(@typeInfo(@TypeOf(result)) == .pointer);
    const ResultList = comptime @typeInfo(@TypeOf(result)).pointer.child;
    const Result = comptime @typeInfo(
        @FieldType(ResultList, "items"),
    ).pointer.child;
    comptime std.debug.assert(ResultList == std.ArrayListUnmanaged(Result));

    // On any error the partially-decoded message is abandoned by the
    // caller — `protobuf.decode` returns the error WITHOUT deiniting
    // `result` — so this call owns full cleanup of the accumulated list
    // (its elements AND its backing storage). The per-element errdefers
    // in the branches below (slice `free`, submessage `deinit`) own the
    // single in-flight element appended during THIS call; this errdefer
    // first drops the elements appended during this call so those
    // per-element errdefers are not double-freed, then deinitializes
    // every previously-committed element and frees the list. Leaving the
    // list `.empty` keeps any higher-level deinit a no-op (CWE-401 leak
    // and double-free safe). The old "restore to entry capacity"
    // errdefer (`shrinkAndFree(current_capacity)`) was unsound: it
    // asserts `new_len <= items.len`, which fails whenever this call is
    // entered with capacity slack (any 2nd+ packed record, or the Nth
    // element of an unpacked repeated string/submessage), and it leaked
    // the previously-committed elements regardless.
    const entry_items = result.items.len;
    errdefer {
        // Per-element errdefers below already freed the in-flight
        // element's owned memory; drop its now-dangling slot(s) so the
        // element-aware deinit loop does not touch it again.
        if (result.items.len > entry_items) {
            result.shrinkRetainingCapacity(entry_items);
        }
        // Free every element committed before this call, then the list.
        switch (comptime field) {
            .scalar => |scalar| {
                if (comptime scalar.isSlice()) {
                    for (result.items) |item| {
                        if (item.len > 0) allocator.free(item);
                    }
                }
            },
            .submessage => {
                for (result.items) |*item| {
                    item.deinit(allocator);
                }
            },
            .@"enum" => {},
        }
        result.deinit(allocator);
        result.* = .empty;
    }

    switch (comptime field) {
        .scalar => |scalar| {
            if (comptime scalar.isSlice()) {
                // string/bytes are length-delimited, and cannot be packed.
                std.debug.assert(options.bytes != null);

                if (options.bytes.? > max_decode_alloc_per_field) {
                    @branchHint(.cold);
                    return error.InvalidInput;
                }

                const bytes = try allocator.alloc(u8, options.bytes.?);
                errdefer allocator.free(bytes);
                try reader.readSliceAll(bytes);

                try result.append(allocator, bytes);
                if (result.items.len > max_decode_elements) {
                    @branchHint(.cold);
                    return error.InvalidInput;
                }
                return bytes.len;
            }
            // Packed repeated scalar.
            else if (options.bytes) |bytes| {
                if (comptime use_ensure_capacity_packed) {
                    // Reserve list capacity once. For fixed-width
                    // scalars the count is exact; for variable-width
                    // scalars the lower bound (each varint is at
                    // least 1 byte) is a conservative upper bound on
                    // the element count and avoids per-element
                    // reallocs without over-allocating beyond the
                    // raw payload size already in memory.
                    const expected_count: usize = if (comptime scalar.isFixed()) blk: {
                        const elem_size = @sizeOf(scalar.toType());
                        break :blk if (elem_size == 0) bytes else bytes / elem_size;
                    } else bytes;
                    if (expected_count > max_decode_elements) {
                        @branchHint(.cold);
                        return error.InvalidInput;
                    }
                    // Fixed-width count is exact; reserve it directly. The
                    // variable-width upper bound (`bytes`) can over-reserve
                    // up to 10x, so cap eager reservation and let amortized
                    // growth cover larger lists.
                    const reserve = if (comptime scalar.isFixed())
                        expected_count
                    else
                        @min(expected_count, max_decode_reserve_elements);
                    try result.ensureTotalCapacity(allocator, result.items.len + reserve);
                }

                var consumed: usize = 0;
                while (consumed < bytes) {
                    const decoded, const c = try decodeScalar(scalar, reader);
                    try result.append(allocator, decoded);
                    // Cumulative cap: a packed field may span multiple wire
                    // records that concatenate into `result`, so this checks
                    // the persistent accumulator, not just this record. The
                    // pre-loop guard only bounds a single record's count, so
                    // this check must run regardless of the reservation flag
                    // (CWE-789 cross-record amplification).
                    if (result.items.len > max_decode_elements) {
                        @branchHint(.cold);
                        return error.InvalidInput;
                    }
                    consumed += c;
                }
                if (consumed != bytes) {
                    @branchHint(.cold);
                    return error.InvalidInput;
                }
                return bytes;
            }
            // Unpacked repeated scalar.
            else {
                const decoded, const consumed =
                    try decodeScalar(scalar, reader);
                try result.append(allocator, decoded);
                if (result.items.len > max_decode_elements) {
                    @branchHint(.cold);
                    return error.InvalidInput;
                }
                return consumed;
            }
        },
        .@"enum" => {
            // Packed repeated enum.
            if (options.bytes) |bytes| {
                if (comptime use_ensure_capacity_packed) {
                    // Enums are varint-encoded (1-10 bytes each), so the
                    // wire byte count is a loose upper bound on element
                    // count — up to 10x too high. Reject obviously-oversized
                    // payloads, then cap the eager reservation and let
                    // ArrayList amortized growth cover larger lists.
                    if (bytes > max_decode_elements) {
                        @branchHint(.cold);
                        return error.InvalidInput;
                    }
                    const reserve = @min(bytes, max_decode_reserve_elements);
                    try result.ensureTotalCapacity(allocator, result.items.len + reserve);
                }

                var consumed: usize = 0;
                while (consumed < bytes) {
                    const raw, const c = try decodeScalar(.int32, reader);
                    const decoded: Result = try enumFromWire(Result, raw);
                    try result.append(allocator, decoded);
                    // Cumulative cap across records — see the packed scalar
                    // path above; must run regardless of the reservation flag
                    // (CWE-789 cross-record amplification).
                    if (result.items.len > max_decode_elements) {
                        @branchHint(.cold);
                        return error.InvalidInput;
                    }
                    consumed += c;
                }
                if (consumed > bytes) {
                    @branchHint(.cold);
                    return error.InvalidInput;
                }
                return consumed;
            }
            // Unpacked repeated enum.
            else {
                const raw, const consumed = try decodeScalar(.int32, reader);
                const decoded: Result = try enumFromWire(Result, raw);
                try result.append(allocator, decoded);
                if (result.items.len > max_decode_elements) {
                    @branchHint(.cold);
                    return error.InvalidInput;
                }
                return consumed;
            }
        },
        .submessage => {
            // Submessages are length-delimited, and cannot be packed.
            std.debug.assert(options.bytes != null);

            try result.append(
                allocator,
                try protobuf.init(Result, allocator),
            );
            if (result.items.len > max_decode_elements) {
                @branchHint(.cold);
                return error.InvalidInput;
            }
            errdefer result.items[result.items.len - 1].deinit(allocator);
            const msg = &result.items[result.items.len - 1];
            const consumed = try decodeMessage(
                msg,
                allocator,
                reader,
                .{ .bytes = options.bytes, ._depth = options._depth + 1 },
            );
            if (consumed > options.bytes.?) {
                @branchHint(.cold);
                return error.InvalidInput;
            }
            return consumed;
        },
    }
}

test decodeRepeated {
    // length delimited message including a list of varints
    {
        const bytes: []const u8 = &.{ 0x03, 0x8e, 0x02, 0x9e, 0xa7, 0x05 };
        var list: std.ArrayListUnmanaged(u32) = .empty;
        defer list.deinit(std.testing.allocator);

        var reader: std.Io.Reader = .fixed(bytes);

        const consumed = try decodeRepeated(
            &list,
            std.testing.allocator,
            .{ .scalar = .uint32 },
            &reader,
            .{
                .bytes = bytes.len,
            },
        );
        try std.testing.expectEqual(bytes.len, consumed);
        try std.testing.expectEqualSlices(
            u32,
            &.{ 3, 270, 86942 },
            list.items,
        );
    }
}

/// Decode a message from reader.
pub fn decodeMessage(
    result: anytype,
    allocator: std.mem.Allocator,
    reader: anytype,
    options: struct {
        /// Number of bytes to parse. Provided for all submessages.
        bytes: ?usize = null,
        /// Internal: current submessage recursion depth. Bumped on each
        /// recursive entry; when this exceeds `max_decode_depth` the
        /// decoder returns `error.InvalidInput` before further stack
        /// growth (CWE-674 mitigation).
        _depth: u32 = 0,
    },
) DecodeError!usize {
    if (options._depth > max_decode_depth) {
        @branchHint(.cold);
        return error.InvalidInput;
    }

    comptime std.debug.assert(@typeInfo(@TypeOf(result)) == .pointer);
    const Result = comptime @typeInfo(@TypeOf(result)).pointer.child;
    const ResultField = std.meta.FieldEnum(Result);
    comptime std.debug.assert(@TypeOf(result) == *Result);
    const desc_table = Result._desc_table;

    var consumed: usize = 0;
    main_loop: while (true) {
        const tag: Tag, const tag_c = b: {
            if (options.bytes) |b| {
                if (consumed < b) {
                    break :b try Tag.decode(reader);
                } else break :main_loop;
            } else {
                break :b Tag.decode(reader) catch |e| switch (e) {
                    error.EndOfStream => break :main_loop,
                    else => return e,
                };
            }
        };
        consumed += tag_c;

        @setEvalBranchQuota(200_000);
        inline for (@typeInfo(@TypeOf(desc_table)).@"struct".fields) |field| {
            const field_desc: protobuf.FieldDescriptor =
                comptime @field(desc_table, field.name);
            const field_info: std.builtin.Type.StructField =
                std.meta.fieldInfo(Result, @field(ResultField, field.name));

            if (comptime field_desc.ftype != .oneof) {
                if (comptime field_desc.field_number == null)
                    comptime continue;
                const fnum = comptime field_desc.field_number.?;
                if (fnum != tag.field) comptime continue;
                if (comptime field_desc.ftype == .packed_repeated) {
                    // Packed repeated fields may be encoded as non-packed.
                    if (tag.wire_type != .len and
                        tag.wire_type != field_desc.ftype.packed_repeated.toWire())
                    {
                        @branchHint(.cold);
                        return error.InvalidInput;
                    }
                } else if (comptime field_desc.ftype == .repeated) {
                    // Non-packed repeated fields may be encoded as packed.
                    if (tag.wire_type != .len and
                        tag.wire_type != field_desc.ftype.repeated.toWire())
                    {
                        @branchHint(.cold);
                        return error.InvalidInput;
                    }
                } else if (tag.wire_type != comptime field_desc.ftype.toWire()) {
                    @branchHint(.cold);
                    return error.InvalidInput;
                }
            }

            const Field = comptime @FieldType(Result, field.name);
            const field_ti = comptime @typeInfo(Field);

            switch (comptime field_desc.ftype) {
                .scalar => |scalar| {
                    if (comptime scalar.isSlice()) {
                        if (tag.wire_type != .len) {
                            @branchHint(.cold);
                            return error.InvalidInput;
                        }
                        std.debug.assert(tag.wire_type == .len);
                        const len, const len_c =
                            try decodeScalar(.int32, reader);
                        consumed += len_c;
                        if (len < 0) {
                            @branchHint(.cold);
                            return error.InvalidInput;
                        }
                        if (@as(usize, @intCast(len)) > max_decode_alloc_per_field) {
                            @branchHint(.cold);
                            return error.InvalidInput;
                        }

                        const new: []u8 = if (len > 0)
                            try allocator.alloc(u8, @intCast(len))
                        else
                            &.{};
                        errdefer if (len > 0) allocator.free(new);

                        if (len > 0) {
                            try reader.readSliceAll(new);
                            consumed += @intCast(len);
                        }

                        // Free potentially existing string/bytes before
                        // replacing field.
                        if (comptime Field == []const u8) {
                            const existing: []const u8 =
                                @field(result, field.name);
                            if (comptime field_info.defaultValue()) |default| {
                                if (default.ptr != existing.ptr and
                                    existing.len > 0)
                                {
                                    allocator.free(existing);
                                }
                            } else if (existing.len > 0) {
                                allocator.free(existing);
                            }
                        } else if (comptime Field == ?[]const u8) {
                            if (@field(result, field.name)) |existing| {
                                if (existing.len > 0) {
                                    if (comptime field_info.defaultValue()) |opt| {
                                        if (comptime opt != null) {
                                            if (opt.?.ptr != existing.ptr) {
                                                allocator.free(existing);
                                            }
                                        }
                                    } else {
                                        allocator.free(existing);
                                    }
                                }
                            }
                        } else unreachable;

                        @field(result, field.name) = new;
                    } else {
                        const val, const c = try decodeScalar(scalar, reader);
                        consumed += c;
                        @field(result, field.name) = val;
                    }
                },
                .@"enum" => {
                    const raw, const c = try decodeScalar(.int32, reader);
                    consumed += c;
                    const decoded = b: {
                        if (comptime field_ti == .optional) {
                            const val: field_ti.optional.child =
                                try enumFromWire(field_ti.optional.child, raw);
                            break :b val;
                        } else {
                            const val: Field = try enumFromWire(Field, raw);
                            break :b val;
                        }
                    };
                    @field(result, field.name) = decoded;
                },
                .packed_repeated => |repeated| {
                    const is_null = if (comptime field_ti == .optional) b: {
                        if (@field(result, field.name) == null) {
                            @field(result, field.name) = .empty;
                            break :b true;
                        }
                        break :b false;
                    } else false;
                    errdefer if (comptime field_ti == .optional) {
                        if (is_null) {
                            @field(result, field.name) = null;
                        }
                    };

                    // Packed encoding.
                    if (tag.wire_type == .len) {
                        const len, const c = try decodeScalar(.int32, reader);
                        consumed += c;

                        if (len < 0) {
                            @branchHint(.cold);
                            return error.InvalidInput;
                        }

                        consumed += try decodeRepeated(
                            if (comptime field_ti == .optional)
                                &@field(result, field.name).?
                            else
                                &@field(result, field.name),
                            allocator,
                            repeated,
                            reader,
                            .{ .bytes = @intCast(len), ._depth = options._depth },
                        );
                    }
                    // Unpacked encoding, despite packed repeated field.
                    else {
                        consumed += try decodeRepeated(
                            if (comptime field_ti == .optional)
                                &@field(result, field.name).?
                            else
                                &@field(result, field.name),
                            allocator,
                            repeated,
                            reader,
                            .{ ._depth = options._depth },
                        );
                    }
                },
                .repeated => |repeated| {
                    const is_null = if (comptime field_ti == .optional) b: {
                        if (@field(result, field.name) == null) {
                            @field(result, field.name) = .empty;
                            break :b true;
                        }
                        break :b false;
                    } else false;
                    errdefer if (comptime field_ti == .optional) {
                        if (is_null) {
                            @field(result, field.name) = null;
                        }
                    };
                    const len: ?usize = if (tag.wire_type == .len) b: {
                        const len, const c = try decodeScalar(.int32, reader);
                        consumed += c;
                        if (len < 0) {
                            @branchHint(.cold);
                            return error.InvalidInput;
                        }
                        break :b @intCast(len);
                    } else null;
                    consumed += try decodeRepeated(
                        &@field(result, field.name),
                        allocator,
                        repeated,
                        reader,
                        .{ .bytes = len, ._depth = options._depth },
                    );
                },
                .submessage => {
                    std.debug.assert(tag.wire_type == .len);

                    const len, const c = try decodeScalar(.int32, reader);
                    consumed += c;
                    if (len < 0) {
                        @branchHint(.cold);
                        return error.InvalidInput;
                    }

                    // All submessages must be optional; submessages always
                    // have an explicit field presence, which means the
                    // absence of a submessage in wire encoding must always
                    // refer to the *lack of* a submessage rather than a
                    // "default" submessage.
                    std.debug.assert(field_ti == .optional);
                    const inner_ti = @typeInfo(field_ti.optional.child);

                    if (comptime inner_ti == .pointer) {
                        const SubMessage = inner_ti.pointer.child;
                        const is_null = b: {
                            if (@field(result, field.name) == null) {
                                @field(result, field.name) =
                                    try allocator.create(SubMessage);
                                errdefer allocator.destroy(
                                    @field(result, field.name).?,
                                );

                                @field(result, field.name).?.* =
                                    try protobuf.init(SubMessage, allocator);
                                break :b true;
                            }
                            break :b false;
                        };
                        errdefer if (is_null) {
                            @field(result, field.name).?.deinit(allocator);
                            allocator.destroy(@field(result, field.name).?);
                            @field(result, field.name) = null;
                        };

                        if (len > 0) {
                            const message_consumed = try decodeMessage(
                                @field(result, field.name).?,
                                allocator,
                                reader,
                                .{ .bytes = @intCast(len), ._depth = options._depth + 1 },
                            );
                            if (message_consumed > len) {
                                @branchHint(.cold);
                                return error.InvalidInput;
                            }
                            consumed += message_consumed;
                        }
                    } else {
                        const SubMessage = field_ti.optional.child;
                        const is_null = b: {
                            if (@field(result, field.name) == null) {
                                @field(result, field.name) =
                                    try protobuf.init(SubMessage, allocator);
                                break :b true;
                            }
                            break :b false;
                        };
                        errdefer if (is_null) {
                            @field(result, field.name).?.deinit(allocator);
                            @field(result, field.name) = null;
                        };

                        if (len > 0) {
                            const message_consumed = try decodeMessage(
                                &@field(result, field.name).?,
                                allocator,
                                reader,
                                .{ .bytes = @intCast(len), ._depth = options._depth + 1 },
                            );
                            if (message_consumed > len) {
                                @branchHint(.cold);
                                return error.InvalidInput;
                            }
                            consumed += message_consumed;
                        }
                    }
                },
                .oneof => |OneOf| {
                    // All oneof fields are necessarily optional, as none of
                    // the fields are active by default.
                    comptime std.debug.assert(field_ti == .optional);
                    comptime std.debug.assert(
                        field_ti.optional.child == OneOf,
                    );
                    const oneof_ti = comptime @typeInfo(OneOf).@"union";

                    const inner_desc_table = comptime OneOf._desc_table;
                    oo_fields: inline for (oneof_ti.fields) |oo_field| {
                        const inner_desc: protobuf.FieldDescriptor =
                            comptime @field(inner_desc_table, oo_field.name);

                        if (comptime inner_desc.field_number == null)
                            comptime continue :oo_fields;
                        if (inner_desc.field_number.? != tag.field) {
                            comptime continue :oo_fields;
                        }

                        if (inner_desc.ftype.toWire() != tag.wire_type) {
                            @branchHint(.cold);
                            return error.InvalidInput;
                        }

                        const oo_field_ti = @typeInfo(oo_field.type);
                        switch (comptime inner_desc.ftype) {
                            .scalar => |scalar| {
                                if (comptime scalar.isSlice()) {
                                    std.debug.assert(tag.wire_type == .len);

                                    // `oneof` fields are always non-optional
                                    // as `oneof` has explicit presence.
                                    std.debug.assert(
                                        oo_field.type == []const u8,
                                    );

                                    std.debug.assert(tag.wire_type == .len);
                                    const len, const len_c =
                                        try decodeScalar(.int32, reader);
                                    consumed += len_c;

                                    if (len < 0) {
                                        @branchHint(.cold);
                                        return error.InvalidInput;
                                    }
                                    if (@as(usize, @intCast(len)) > max_decode_alloc_per_field) {
                                        @branchHint(.cold);
                                        return error.InvalidInput;
                                    }

                                    const new: []u8 = if (len > 0)
                                        try allocator.alloc(u8, @intCast(len))
                                    else
                                        &.{};
                                    errdefer if (len > 0) allocator.free(new);

                                    if (len > 0) {
                                        try reader.readSliceAll(new);
                                        consumed += @intCast(len);
                                    }

                                    // Free potentially existing union field
                                    // just before replacing.
                                    protobuf.deinitOneof(
                                        &@field(result, field.name),
                                        allocator,
                                    );

                                    @field(result, field.name) = @unionInit(
                                        OneOf,
                                        oo_field.name,
                                        new,
                                    );
                                } else {
                                    const val, const c =
                                        try decodeScalar(scalar, reader);
                                    consumed += c;
                                    @field(result, field.name) = @unionInit(
                                        OneOf,
                                        oo_field.name,
                                        val,
                                    );
                                }
                            },
                            .@"enum" => {
                                const raw, const c =
                                    try decodeScalar(.int32, reader);
                                consumed += c;
                                const decoded: oo_field.type =
                                    try enumFromWire(oo_field.type, raw);

                                // Free potentially existing union field just
                                // before replacing.
                                protobuf.deinitOneof(
                                    &@field(result, field.name),
                                    allocator,
                                );

                                @field(result, field.name) = @unionInit(
                                    OneOf,
                                    oo_field.name,
                                    decoded,
                                );
                            },
                            .submessage => {
                                std.debug.assert(tag.wire_type == .len);

                                const len, const c =
                                    try decodeScalar(.int32, reader);
                                consumed += c;

                                if (len < 0) {
                                    @branchHint(.cold);
                                    return error.InvalidInput;
                                }

                                // Submessages are non-optional, as `oneof`s
                                // also have explicit presence.
                                comptime std.debug.assert(
                                    oo_field_ti == .@"struct" or
                                        oo_field_ti == .pointer,
                                );

                                const SubMessage =
                                    if (comptime oo_field_ti == .pointer)
                                        oo_field_ti.pointer.child
                                    else
                                        oo_field.type;

                                if (@field(result, field.name) != null) {
                                    // If a matching submessage field already
                                    // exists, the incoming submessage is
                                    // merged. Otherwise, the existing field
                                    // is freed and set to null.
                                    const incoming_tag = comptime @field(
                                        std.meta.Tag(OneOf),
                                        oo_field.name,
                                    );
                                    if (std.meta.activeTag(
                                        @field(result, field.name).?,
                                    ) != incoming_tag) {
                                        protobuf.deinitOneof(
                                            &@field(result, field.name),
                                            allocator,
                                        );

                                        std.debug.assert(@field(
                                            result,
                                            field.name,
                                        ) == null);
                                    }
                                }
                                const is_null =
                                    @field(result, field.name) == null;
                                if (comptime oo_field_ti == .pointer) {
                                    if (is_null) {
                                        @field(result, field.name) = @unionInit(
                                            OneOf,
                                            oo_field.name,
                                            try allocator.create(SubMessage),
                                        );
                                        @field(
                                            @field(result, field.name).?,
                                            oo_field.name,
                                        ) = try .init(allocator);
                                    }
                                    errdefer if (is_null) {
                                        @field(@field(
                                            result,
                                            field.name,
                                        ).?, oo_field.name).deinit(allocator);
                                        allocator.destroy(
                                            @field(result, field.name).?,
                                        );
                                        @field(result, field.name) = null;
                                    };

                                    if (len > 0) {
                                        const m_consumed = try decodeMessage(
                                            @field(
                                                @field(result, field.name).?,
                                                oo_field.name,
                                            ),
                                            allocator,
                                            reader,
                                            .{ .bytes = @intCast(len), ._depth = options._depth + 1 },
                                        );
                                        if (m_consumed > len) {
                                            @branchHint(.cold);
                                            return error.InvalidInput;
                                        }
                                        consumed += m_consumed;
                                    }
                                } else {
                                    if (is_null) {
                                        @field(result, field.name) =
                                            @unionInit(
                                                OneOf,
                                                oo_field.name,
                                                try protobuf.init(
                                                    SubMessage,
                                                    allocator,
                                                ),
                                            );
                                    }
                                    errdefer if (is_null) {
                                        @field(
                                            @field(result, field.name).?,
                                            oo_field.name,
                                        ).deinit(allocator);
                                        @field(result, field.name) = null;
                                    };

                                    if (len > 0) {
                                        const m_consumed = try decodeMessage(
                                            &@field(
                                                @field(result, field.name).?,
                                                oo_field.name,
                                            ),
                                            allocator,
                                            reader,
                                            .{ .bytes = @intCast(len), ._depth = options._depth + 1 },
                                        );
                                        if (m_consumed > len) {
                                            @branchHint(.cold);
                                            return error.InvalidInput;
                                        }
                                        consumed += m_consumed;
                                    }
                                }
                            },
                            .oneof,
                            .repeated,
                            .packed_repeated,
                            => unreachable,
                        }
                        break :oo_fields;
                    } else consumed += try skipField(reader, tag, options._depth + 1);
                },
            }
            comptime break;
        } else consumed += try skipField(reader, tag, options._depth + 1);
    }
    return consumed;
}

fn skipField(reader: anytype, tag: Tag, depth: u32) DecodeError!usize {
    if (depth > max_decode_depth) {
        @branchHint(.cold);
        return error.InvalidInput;
    }
    var consumed: usize = 0;

    // If field number was not found, skip unknown field.
    log.debug(
        "Unknown field received in {any}\n",
        .{tag},
    );
    switch (tag.wire_type) {
        .fixed32 => {
            try reader.discardAll(4);
            consumed += 4;
        },
        .fixed64 => {
            try reader.discardAll(8);
            consumed += 8;
        },
        .len => {
            const skip, const c = try decodeScalar(.int32, reader);
            consumed += c;
            if (skip < 0) {
                @branchHint(.cold);
                return error.InvalidInput;
            }
            try reader.discardAll(@intCast(skip));
            consumed += @intCast(skip);
        },
        .varint => {
            _, const c = try decodeScalar(.uint64, reader);
            consumed += c;
        },
        .sgroup => {
            // proto2 group: scan inner tags until the matching egroup.
            // The previous empty body consumed zero bytes, letting the
            // outer decode loop spin forever on malformed input (CWE-835).
            while (true) {
                const inner, const c = try Tag.decode(reader);
                consumed += c;
                if (inner.wire_type == .egroup) {
                    if (inner.field != tag.field) {
                        @branchHint(.cold);
                        return error.InvalidInput;
                    }
                    break;
                }
                consumed += try skipField(reader, inner, depth + 1);
            }
        },
        .egroup => {
            // Stray egroup without matching sgroup is malformed.
            @branchHint(.cold);
            return error.InvalidInput;
        },
    }

    return consumed;
}

test {
    _ = Tag;
    _ = ZigZag;
}
