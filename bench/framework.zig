//! Bench harness framework — shared scaffolding used by every scenario.
//!
//! Owns the bench result schema, JSON record emission, the
//! CountingAllocator used for zero-alloc probes, the `sink` helper
//! that defeats dead-code elimination, and the timing helpers.
//!
//! No third-party benchmark library is used; everything here is
//! stdlib-only per native-benchmarks methodology.
//!
//! Targets Zig 0.16.0 — `std.time.Instant`, `std.time.Timer`, and
//! `std.time.timestamp` were all removed in 0.16. We use the new
//! `std.Io.Clock` API for monotonic timing and a wall-clock unix
//! timestamp.

const std = @import("std");
const builtin = @import("builtin");

/// Schema version emitted in every record. Bumped only when fields
/// change in a non-additive way.
pub const SCHEMA_VERSION: []const u8 = "1";

/// Layer label for a scenario; determines default round/iteration counts
/// and which build step exercises it.
pub const Layer = enum { micro, integration, comparison };

/// Bench-wide CLI options parsed once in `main`.
pub const RunOptions = struct {
    scenario: ?[]const u8 = null,
    rounds: u32 = 10,
    warmups: u32 = 1,
    iterations: ?u64 = null,
    out_dir: []const u8 = "raw/",
    /// Set when `out_dir` was duplicated from argv (and therefore
    /// owned by the parser's allocator). The CLI driver checks this
    /// to know whether to free `out_dir` on exit.
    out_dir_owned: bool = false,
    smoke: bool = false,
    /// Resolved at runtime from the BENCH_GIT_SHA environment variable.
    /// Stamped into every emitted JSON record so the AB runner and
    /// `compare.py` can correlate records back to a commit.
    git_sha: []const u8 = "unknown",
    /// Optional override of layer-default round count when the build
    /// step needs a different default than --rounds without the user
    /// passing --rounds explicitly.
    layer_default_rounds: ?u32 = null,
    layer_default_warmups: ?u32 = null,
};

/// Counting allocator — wraps any backing allocator and tallies bytes
/// requested (via `alloc`/`resize`) and bytes freed. The bench emits
/// `alloc_delta_bytes = total_alloc - total_free` so a balanced
/// alloc-then-free pair still surfaces as zero (which is what the
/// zero-alloc contract really asks for: no net heap growth in the
/// hot path).
pub const CountingAllocator = struct {
    backing: std.mem.Allocator,
    total_alloc: u64 = 0,
    total_free: u64 = 0,
    alloc_count: u64 = 0,
    free_count: u64 = 0,

    pub fn init(backing: std.mem.Allocator) CountingAllocator {
        return .{ .backing = backing };
    }

    pub fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = vtableAlloc,
                .resize = vtableResize,
                .remap = vtableRemap,
                .free = vtableFree,
            },
        };
    }

    pub fn reset(self: *CountingAllocator) void {
        self.total_alloc = 0;
        self.total_free = 0;
        self.alloc_count = 0;
        self.free_count = 0;
    }

    /// Net bytes outstanding (allocated minus freed). Zero means the
    /// hot path produced no net heap growth.
    pub fn netBytes(self: *const CountingAllocator) i128 {
        return @as(i128, self.total_alloc) - @as(i128, self.total_free);
    }

    fn vtableAlloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const result = self.backing.rawAlloc(len, alignment, ret_addr);
        if (result != null) {
            self.total_alloc += len;
            self.alloc_count += 1;
        }
        return result;
    }

    fn vtableResize(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const ok = self.backing.rawResize(memory, alignment, new_len, ret_addr);
        if (ok) {
            if (new_len > memory.len) {
                self.total_alloc += new_len - memory.len;
            } else if (memory.len > new_len) {
                self.total_free += memory.len - new_len;
            }
        }
        return ok;
    }

    fn vtableRemap(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const result = self.backing.rawRemap(memory, alignment, new_len, ret_addr);
        if (result != null) {
            if (new_len > memory.len) {
                self.total_alloc += new_len - memory.len;
            } else if (memory.len > new_len) {
                self.total_free += memory.len - new_len;
            }
            self.alloc_count += 1;
        }
        return result;
    }

    fn vtableFree(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(memory, alignment, ret_addr);
        self.total_free += memory.len;
        self.free_count += 1;
    }
};

/// Black-hole sink — passes the value through `std.mem.doNotOptimizeAway`
/// so the optimizer can't eliminate the hot loop body. `noinline` keeps
/// the compiler from peering inside and reasoning that the call is a
/// no-op.
pub noinline fn sink(comptime T: type, v: T) void {
    std.mem.doNotOptimizeAway(v);
}

/// Per-round metric snapshot computed across N inner iterations.
pub const RoundMetrics = struct {
    ns_per_op_median: f64,
    ns_per_op_p50: f64,
    ns_per_op_p95: f64,
    ns_per_op_p99: f64,
    ns_per_op_stddev: f64,
    ns_per_op_min: f64,
    ns_per_op_max: f64,
};

/// Result of one measured round, including counters from the
/// CountingAllocator and the dead-code-elimination sink output.
pub const RoundResult = struct {
    metrics: RoundMetrics,
    iterations: u64,
    alloc_delta_bytes: i128,
    allocs_per_op: f64,
    bytes_per_op: u64,
    zero_alloc_observed: bool,
};

/// Snapshot wall-clock unix nanoseconds. Used for the JSON `timestamp`
/// field; precision below seconds is not required.
pub fn unixSeconds(io: std.Io) i64 {
    const ts = std.Io.Clock.Timestamp.now(io, .real);
    return @intCast(@divTrunc(ts.raw.nanoseconds, std.time.ns_per_s));
}

/// Format a unix-epoch second count as ISO 8601 UTC into the supplied
/// buffer. Returns the slice within `buf` that holds the formatted
/// value. The output looks like "2026-04-26T17:31:35Z" — 20 bytes
/// always, suffix-Z UTC, no fractional seconds. The buffer must be
/// at least 20 bytes long.
///
/// The native-benchmarks methodology requires ISO 8601 timestamps in
/// every record (per the result-schema skill).
pub fn formatIso8601Utc(buf: []u8, unix_seconds: i64) []const u8 {
    std.debug.assert(buf.len >= 20);
    const secs_per_day: i64 = std.time.s_per_day;
    const day_seconds: i64 = @mod(unix_seconds, secs_per_day);
    const epoch_days: i64 = @divFloor(unix_seconds, secs_per_day);

    const ed: std.time.epoch.EpochDay = .{ .day = @intCast(epoch_days) };
    const yd = ed.calculateYearDay();
    const md = yd.calculateMonthDay();

    const hour: u8 = @intCast(@divFloor(day_seconds, std.time.s_per_hour));
    const min_secs: i64 = @mod(day_seconds, std.time.s_per_hour);
    const minute: u8 = @intCast(@divFloor(min_secs, std.time.s_per_min));
    const second: u8 = @intCast(@mod(min_secs, std.time.s_per_min));

    const year_u: u16 = if (yd.year < 0) 0 else @intCast(yd.year);
    const formatted = std.fmt.bufPrint(
        buf,
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z",
        .{
            year_u,
            md.month.numeric(),
            md.day_index + 1,
            hour,
            minute,
            second,
        },
    ) catch unreachable;
    return formatted;
}

/// Measure a single round of `iterations` calls to `body(ctx)`. Uses
/// per-iteration timing to compute median/p95/p99 distribution. Caller
/// must already have wired the CountingAllocator if it wants alloc
/// counters — this function only times.
pub fn measureRound(
    io: std.Io,
    allocator: std.mem.Allocator,
    iterations: u64,
    input_bytes: u64,
    counting: ?*CountingAllocator,
    comptime CtxType: type,
    ctx: *CtxType,
    comptime body: fn (ctx: *CtxType) anyerror!void,
) !RoundResult {
    if (counting) |c| c.reset();

    // Per-iteration ns samples; allocate from caller's allocator.
    const samples = try allocator.alloc(u64, iterations);
    defer allocator.free(samples);

    var i: u64 = 0;
    while (i < iterations) : (i += 1) {
        const t0 = std.Io.Clock.Timestamp.now(io, .awake);
        try body(ctx);
        const dur = t0.untilNow(io);
        // `Duration.raw.nanoseconds` is i96. Clamp to u64 — negative
        // durations would mean clock went backwards which we treat as
        // zero rather than error.
        const ns: u64 = if (dur.raw.nanoseconds < 0) 0 else @intCast(dur.raw.nanoseconds);
        samples[i] = ns;
    }

    // Compute distribution over per-iteration ns.
    std.mem.sort(u64, samples, {}, std.sort.asc(u64));

    const median: f64 = if (iterations == 0) 0 else blk: {
        const mid = iterations / 2;
        if (iterations % 2 == 1) break :blk @floatFromInt(samples[mid]);
        break :blk (@as(f64, @floatFromInt(samples[mid - 1])) + @as(f64, @floatFromInt(samples[mid]))) / 2.0;
    };

    const p95_idx = if (iterations == 0) 0 else (iterations * 95) / 100;
    const p99_idx = if (iterations == 0) 0 else (iterations * 99) / 100;
    const p50: f64 = median;
    const p95: f64 = if (iterations == 0) 0 else @floatFromInt(samples[@min(p95_idx, iterations - 1)]);
    const p99: f64 = if (iterations == 0) 0 else @floatFromInt(samples[@min(p99_idx, iterations - 1)]);
    const min: f64 = if (iterations == 0) 0 else @floatFromInt(samples[0]);
    const max: f64 = if (iterations == 0) 0 else @floatFromInt(samples[iterations - 1]);

    var sum: f64 = 0;
    for (samples) |s| sum += @floatFromInt(s);
    const mean: f64 = if (iterations == 0) 0 else sum / @as(f64, @floatFromInt(iterations));
    var var_sum: f64 = 0;
    for (samples) |s| {
        const d = @as(f64, @floatFromInt(s)) - mean;
        var_sum += d * d;
    }
    const stddev: f64 = if (iterations <= 1) 0 else std.math.sqrt(var_sum / @as(f64, @floatFromInt(iterations - 1)));

    const alloc_delta: i128 = if (counting) |c| c.netBytes() else 0;
    const allocs_per_op: f64 = if (counting) |c| blk: {
        if (iterations == 0) break :blk 0;
        break :blk @as(f64, @floatFromInt(c.alloc_count)) / @as(f64, @floatFromInt(iterations));
    } else 0;

    return .{
        .metrics = .{
            .ns_per_op_median = median,
            .ns_per_op_p50 = p50,
            .ns_per_op_p95 = p95,
            .ns_per_op_p99 = p99,
            .ns_per_op_stddev = stddev,
            .ns_per_op_min = min,
            .ns_per_op_max = max,
        },
        .iterations = iterations,
        .alloc_delta_bytes = alloc_delta,
        .allocs_per_op = allocs_per_op,
        .bytes_per_op = input_bytes,
        .zero_alloc_observed = alloc_delta == 0,
    };
}

/// Static descriptor for a scenario. Each scenario file exposes one
/// of these per workload; `main.zig` concatenates them into the
/// run-time registry.
pub const Scenario = struct {
    id: []const u8,
    layer: Layer,
    /// Marker for the zero-alloc contract. When true, `runScenario`
    /// will fail the process with exit code 1 if the measured net
    /// heap growth across the timing loop is non-zero.
    zero_alloc_expected: bool,
    /// Default per-round inner iteration count. Overridable via
    /// `--iterations`.
    default_iterations: u64,
    /// Bytes-of-input metadata recorded into the JSON record's
    /// `bytes_per_op` field.
    input_bytes: u64,
    /// Run callback: emits per-round JSON files into `out_dir`.
    run: *const fn (
        io: std.Io,
        allocator: std.mem.Allocator,
        opts: RunOptions,
        scenario: *const Scenario,
    ) anyerror!void,
};

/// Resolve `BENCH_GIT_SHA` from the process environment and dupe it
/// into `allocator`. Returns the literal `"unknown"` (a comptime
/// string, not heap-owned) when the env var is absent or empty.
/// Caller must `allocator.free` the returned slice when it differs
/// from `"unknown"`.
pub fn resolveGitSha(allocator: std.mem.Allocator, environ: std.process.Environ) ![]const u8 {
    const v = environ.getPosix("BENCH_GIT_SHA") orelse return "unknown";
    if (v.len == 0) return "unknown";
    return try allocator.dupe(u8, v);
}

/// Top-level orchestration helper used by every scenario callback.
/// Performs `warmups` discarded rounds, then `rounds` measured rounds.
/// Each measured round writes one JSON file `round_<NNN>.json` under
/// `out_dir`. Warmup files are written as `warmup_<NNN>.json`.
pub fn driveScenario(
    io: std.Io,
    allocator: std.mem.Allocator,
    opts: RunOptions,
    scenario: *const Scenario,
    counting: ?*CountingAllocator,
    comptime CtxType: type,
    ctx: *CtxType,
    comptime body: fn (ctx: *CtxType) anyerror!void,
) !void {
    const iterations = opts.iterations orelse scenario.default_iterations;
    const rounds = opts.rounds;
    const warmups = opts.warmups;

    var w: u32 = 0;
    while (w < warmups) : (w += 1) {
        const result = try measureRound(io, allocator, iterations, scenario.input_bytes, counting, CtxType, ctx, body);
        try writeRoundFile(io, allocator, opts.out_dir, opts.git_sha, scenario, true, w, &result, iterations);
    }

    var r: u32 = 0;
    while (r < rounds) : (r += 1) {
        const result = try measureRound(io, allocator, iterations, scenario.input_bytes, counting, CtxType, ctx, body);
        try writeRoundFile(io, allocator, opts.out_dir, opts.git_sha, scenario, false, r, &result, iterations);

        if (scenario.zero_alloc_expected and !result.zero_alloc_observed) {
            std.debug.print(
                "FATAL: zero-alloc assertion failed for {s}: alloc_delta_bytes={d}\n",
                .{ scenario.id, result.alloc_delta_bytes },
            );
            std.process.exit(1);
        }
    }
}

/// Smoke flow: one round, no output files. Used by `bench-smoke` to
/// verify that every scenario at least compiles and runs end-to-end
/// on the target platform.
pub fn smokeScenario(
    io: std.Io,
    allocator: std.mem.Allocator,
    scenario: *const Scenario,
    counting: ?*CountingAllocator,
    comptime CtxType: type,
    ctx: *CtxType,
    comptime body: fn (ctx: *CtxType) anyerror!void,
) !void {
    // Smoke uses a tiny iteration count so even a slow scenario fits
    // within the smoke budget.
    const iterations: u64 = @min(scenario.default_iterations, 1000);
    _ = try measureRound(io, allocator, iterations, scenario.input_bytes, counting, CtxType, ctx, body);
}

fn writeRoundFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    out_dir: []const u8,
    git_sha: []const u8,
    scenario: *const Scenario,
    is_warmup: bool,
    round_idx: u32,
    result: *const RoundResult,
    iterations: u64,
) !void {
    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, out_dir) catch |err| switch (err) {
        // PathAlreadyExists isn't an error from createDirPath in 0.16,
        // but defensively map any unexpected error verbatim.
        else => return err,
    };

    const filename = try std.fmt.allocPrint(
        allocator,
        "{s}_{s}_{d:0>3}.json",
        .{
            if (is_warmup) "warmup" else "round",
            scenario.id,
            round_idx,
        },
    );
    defer allocator.free(filename);

    const path = try std.fs.path.join(allocator, &.{ out_dir, filename });
    defer allocator.free(path);

    const file = try cwd.createFile(io, path, .{});
    defer file.close(io);

    var buf: [4096]u8 = undefined;
    var fw = file.writer(io, &buf);
    const w = &fw.interface;

    var ts_buf: [32]u8 = undefined;
    const ts_iso = formatIso8601Utc(&ts_buf, unixSeconds(io));
    try emitRecord(w, scenario, is_warmup, round_idx, result, iterations, ts_iso, git_sha);
    try w.flush();
}

fn emitRecord(
    w: *std.Io.Writer,
    scenario: *const Scenario,
    is_warmup: bool,
    round_idx: u32,
    result: *const RoundResult,
    iterations: u64,
    ts_iso: []const u8,
    git_sha: []const u8,
) !void {
    try w.writeAll("{\n");
    try w.print("  \"schema_version\": \"{s}\",\n", .{SCHEMA_VERSION});
    try w.print("  \"scenario_id\": \"{s}\",\n", .{scenario.id});
    try w.print("  \"layer\": \"{s}\",\n", .{@tagName(scenario.layer)});
    try w.writeAll("  \"language\": \"zig\",\n");
    try w.writeAll("  \"variant\": \"A\",\n");
    try w.print("  \"git_sha\": \"{s}\",\n", .{git_sha});
    try w.print("  \"command\": \"zig build bench-{s} -- --scenario {s}\",\n", .{
        @tagName(scenario.layer),
        scenario.id,
    });
    try w.print("  \"timestamp\": \"{s}\",\n", .{ts_iso});
    try w.print("  \"os\": \"{s}\",\n", .{@tagName(builtin.os.tag)});
    try w.print("  \"arch\": \"{s}\",\n", .{@tagName(builtin.cpu.arch)});
    try w.print("  \"runtime_version\": \"zig {s}\",\n", .{builtin.zig_version_string});
    try w.print("  \"warmups\": {d},\n", .{if (is_warmup) @as(u32, 1) else @as(u32, 0)});
    try w.print("  \"rounds\": {d},\n", .{@as(u32, 1)});
    try w.print("  \"round\": {d},\n", .{round_idx});
    try w.print("  \"warmup\": {s},\n", .{if (is_warmup) "true" else "false"});
    try w.print("  \"iterations\": {d},\n", .{iterations});

    try w.writeAll("  \"metrics\": {\n");
    try w.print("    \"ns_per_op_median\": {d},\n", .{result.metrics.ns_per_op_median});
    try w.print("    \"ns_per_op_p50\": {d},\n", .{result.metrics.ns_per_op_p50});
    try w.print("    \"ns_per_op_p95\": {d},\n", .{result.metrics.ns_per_op_p95});
    try w.print("    \"ns_per_op_p99\": {d},\n", .{result.metrics.ns_per_op_p99});
    try w.print("    \"ns_per_op_stddev\": {d},\n", .{result.metrics.ns_per_op_stddev});
    try w.print("    \"ns_per_op_min\": {d},\n", .{result.metrics.ns_per_op_min});
    try w.print("    \"ns_per_op_max\": {d}\n", .{result.metrics.ns_per_op_max});
    try w.writeAll("  },\n");

    try w.writeAll("  \"samples\": [");
    try w.print("{d}", .{result.metrics.ns_per_op_median});
    try w.writeAll("],\n");

    try w.writeAll("  \"counters\": {\n");
    try w.print("    \"alloc_delta_bytes\": {d},\n", .{result.alloc_delta_bytes});
    try w.print("    \"allocs_per_op\": {d},\n", .{result.allocs_per_op});
    try w.print("    \"input_bytes\": {d},\n", .{scenario.input_bytes});
    try w.print("    \"bytes_per_op\": {d},\n", .{result.bytes_per_op});
    try w.print("    \"zero_alloc_observed\": {s},\n", .{if (result.zero_alloc_observed) "true" else "false"});
    try w.print("    \"zero_alloc_expected\": {s},\n", .{if (scenario.zero_alloc_expected) "true" else "false"});
    try w.print("    \"alloc_assertion\": \"{s}\",\n", .{if (!scenario.zero_alloc_expected or result.zero_alloc_observed) "pass" else "fail"});
    try w.print("    \"alloc_threshold_bytes\": {d},\n", .{@as(u64, 0)});
    try w.writeAll("    \"concurrency_shape\": \"N=1\"\n");
    try w.writeAll("  }\n");

    try w.writeAll("}\n");
}

/// Parse the bench-binary CLI:
///   --scenario <id>     filter to one scenario
///   --rounds <N>        measured rounds (default: layer-default)
///   --warmups <N>       discarded warmup rounds
///   --iterations <N>    inner iteration count
///   --out <dir>         output directory for round_*.json files
///   --smoke             one-round dry run with no output files
pub fn parseArgs(allocator: std.mem.Allocator, args: std.process.Args) !RunOptions {
    var opts: RunOptions = .{};

    // The Posix iterator does not need an allocator — it walks the
    // argv vector in place. Windows/WASI builds will need
    // `iterateAllocator(allocator)` plus an `it.deinit()`, but the
    // bench harness is Linux/macOS-first so this is fine.
    var it = args.iterate();

    // First entry is the executable path; skip it.
    _ = it.skip();

    while (it.next()) |a| {
        if (std.mem.eql(u8, a, "--scenario")) {
            const v = it.next() orelse return error.MissingArg;
            opts.scenario = try allocator.dupe(u8, v);
        } else if (std.mem.eql(u8, a, "--rounds")) {
            const v = it.next() orelse return error.MissingArg;
            opts.rounds = try std.fmt.parseInt(u32, v, 10);
        } else if (std.mem.eql(u8, a, "--warmups")) {
            const v = it.next() orelse return error.MissingArg;
            opts.warmups = try std.fmt.parseInt(u32, v, 10);
        } else if (std.mem.eql(u8, a, "--iterations")) {
            const v = it.next() orelse return error.MissingArg;
            opts.iterations = try std.fmt.parseInt(u64, v, 10);
        } else if (std.mem.eql(u8, a, "--out")) {
            const v = it.next() orelse return error.MissingArg;
            opts.out_dir = try allocator.dupe(u8, v);
            opts.out_dir_owned = true;
        } else if (std.mem.eql(u8, a, "--smoke")) {
            opts.smoke = true;
        } else {
            std.debug.print("unknown arg: {s}\n", .{a});
            return error.UnknownArg;
        }
    }

    return opts;
}
