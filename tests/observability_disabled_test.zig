//! Verifies the no-op invariant when -Dwith_otel=false (the default).

const std = @import("std");
const protobuf = @import("protobuf");

test "build_options.with_otel exists and defaults to false" {
    const build_options = @import("build_options");
    try std.testing.expect(@hasDecl(build_options, "with_otel"));
    // The "default" assertion only holds for the disabled build. When
    // the operator forces -Dwith_otel=true, this test runs against the
    // enabled module and must skip rather than misreport the default.
    if (build_options.with_otel) return error.SkipZigTest;
    try std.testing.expectEqual(false, build_options.with_otel);
}

test "observability.enabled tracks build_options.with_otel" {
    const build_options = @import("build_options");
    try std.testing.expectEqual(build_options.with_otel, protobuf.observability.enabled);
}

test "no-op when otel disabled" {
    if (protobuf.observability.enabled) return error.SkipZigTest;
    var span = protobuf.observability.startClientSpan(.{
        .method_string = struct {
            fn s() []const u8 {
                return "GET";
            }
        }.s,
        .url_string = struct {
            fn s() []const u8 {
                return "https://x";
            }
        }.s,
    });
    protobuf.observability.endClientSpan(span, 200);
    // Belt-and-suspenders: callers may also invoke `span.end(null)`
    // directly. The seam's `endClientSpan` already covers the lifecycle;
    // this line just verifies the no-op fallback signature matches the
    // real API's `Span.end(?u64) void`.
    span.end(null);
}
