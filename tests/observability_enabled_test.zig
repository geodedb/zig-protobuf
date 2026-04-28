//! Verifies one client span lands in an in-memory recorder when
//! -Dwith_otel=true.
//!
//! Because protobuf has no natural span surface (it's a value-shape
//! library — encode/decode only), this is a degenerate "seam compiles
//! and wires correctly" test rather than a "protobuf emits a span on
//! some operation" test. It instantiates a TracerProvider, points
//! `protobuf.observability.global.tracer` at it, calls
//! `startClientSpan` directly with a duck-typed request, and asserts
//! the in-memory recorder saw exactly one span. This proves the seam
//! is wired correctly even though no protobuf source file calls it.

const std = @import("std");
const build_options = @import("build_options");
const protobuf = @import("protobuf");

// The `otel` module is only added to this test root when
// `-Dwith_otel=true`. To compile cleanly under both flag values we
// gate the import behind a comptime conditional and stub the alias to
// an empty struct when the flag is off — that branch is dead code in
// the disabled build but the import expression resolves.
const otel = if (build_options.with_otel) @import("otel") else struct {};

test "one span recorded when otel enabled" {
    if (!protobuf.observability.enabled) return error.SkipZigTest;

    const allocator = std.testing.allocator;

    var resource = try otel.sdk.resource.defaultResource(allocator);
    defer resource.deinit();
    try resource.attributes.putString(otel.semconv.service_name, "protobuf-test");

    var recorder = otel.exporters.in_memory.Recorder.init(allocator);
    defer recorder.deinit();
    var tp = try otel.sdk.trace.TracerProvider.init(allocator, .{
        .resource = &resource,
        .default_exporter = recorder.spanExporter(),
    });
    defer tp.deinit();

    var tracer = tp.tracer(.{ .name = "protobuf-test" });
    protobuf.observability.global.tracer = &tracer;
    defer protobuf.observability.global.tracer = null;

    const span = protobuf.observability.startClientSpan(.{
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

    try tp.forceFlush(1_000);
    try std.testing.expectEqual(@as(usize, 1), recorder.spans.items.len);
}
