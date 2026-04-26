//! Fuzz harness for the wire decoder.
//!
//! Run with `zig build test --fuzz` to drive the decoder with
//! attacker-controlled bytes via `std.testing.fuzz`. The decoder is
//! expected to either succeed, return one of `wire.DecodeError`, or
//! return `OutOfMemory` from the testing allocator — never crash, hang,
//! or leak under the std.testing.allocator wrapper.
//!
//! Existing regression tests in tests/tests.zig already pin specific
//! malformed-input shapes (deep submessage chain, huge length prefix);
//! this harness extends coverage to randomly-mutated bytes.

const std = @import("std");
const protobuf = @import("protobuf");
const tests_pb = @import("./generated/tests.pb.zig");

// Use a message type with a representative mix of scalars, repeated
// scalars, repeated submessages, strings, bytes, and a oneof variant.
// `WithSubmessages` has nested messages and exercises the recursive
// decode path covered by the S1 / GAP-PB-008 hardening.
const FuzzTarget = tests_pb.WithSubmessages;

fn decodeOne(_: void, smith: *std.testing.Smith) anyerror!void {
    // Pull up to 4 KiB of fuzzer-controlled bytes. `Smith.slice` fills
    // the buffer and returns the actual length consumed.
    var buf: [4096]u8 = undefined;
    const n = smith.slice(buf[0..]);
    if (n == 0) return;

    var reader: std.Io.Reader = .fixed(buf[0..n]);
    // The decoder's full error set is `protobuf.DecodingError ||
    // std.Io.Reader.Error || std.mem.Allocator.Error`. Every variant
    // from those sets is an acceptable malformed-input outcome — what
    // the fuzz harness is hunting for is panics, hangs, leaks, or
    // memory corruption, none of which appear as a returned error.
    var msg = FuzzTarget.decode(&reader, std.testing.allocator) catch return;
    defer msg.deinit(std.testing.allocator);
}

test "fuzz wire decoder" {
    // No seed corpus yet; downstream work can populate one from the
    // existing tests/fixtures/* binaries.
    try std.testing.fuzz({}, decodeOne, .{});
}
