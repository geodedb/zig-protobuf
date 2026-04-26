//! Microbenchmark harness placeholder.
//!
//! Run with `zig build bench`. Currently a smoke run — exercises a
//! few hot paths in a tight loop. Wall-clock timing is intentionally
//! omitted: std.time.Timer was removed in Zig 0.16.0 and the
//! cross-platform replacement has not yet stabilized in the std lib
//! snapshot this repo pins. Use `time zig build bench` or `perf stat`
//! for an external measurement.
//!
//! This file is the placeholder GAP-PB-015 / P-11 / P-12 / P-13 ask
//! for. Downstream perf optimization work (P-01 writeSubmessage, P-02
//! varint fast-path, P-03 decodeMessage switch dispatch, etc.) lands
//! its measurements here.

const std = @import("std");
const protobuf = @import("protobuf");
const wire = protobuf.wire;

pub fn main() !void {
    std.debug.print("zig-protobuf microbenchmark smoke\n", .{});
    std.debug.print("=================================\n", .{});

    const buf1: []const u8 = &[_]u8{0x05} ** 8;
    var i: usize = 0;
    var sum: u64 = 0;
    while (i < 1_000_000) : (i += 1) {
        var reader: std.Io.Reader = .fixed(buf1);
        const v: u64, _ = try wire.decodeScalar(.uint64, &reader);
        sum +%= v;
    }
    std.debug.print("decodeScalar(.uint64) x 1_000_000 done, sum={d}\n", .{sum});

    std.debug.print(
        "\nNote: wall-clock timing not wired (std.time.Timer absent in Zig 0.16.0).\n" ++
            "Use `time zig build bench` or `perf stat` externally.\n",
        .{},
    );
}
