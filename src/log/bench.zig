//! Benchmarks for zefir-log. `zig build bench` builds them with ReleaseFast
//! and prints the environment, then for each scenario the records per
//! second, the caller's latency per record and the records dropped. The
//! output goes to a writer that throws it away, so the numbers measure
//! the logger, not a terminal; a "slow reader" adds a fixed cost to every
//! write the logger makes. The numbers depend on the machine.

const std = @import("std");
const builtin = @import("builtin");
const log = @import("log");

const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    var stdout_buffer: [1024]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(io, &stdout_buffer);
    const out = &stdout.interface;
    defer out.flush() catch {};

    try out.print("zig {s}, {t}-{t}, {s}, {t}, {d} CPUs\n", .{
        builtin.zig_version_string,       builtin.cpu.arch, builtin.os.tag, builtin.cpu.model.name, builtin.mode,
        std.Thread.getCpuCount() catch 0,
    });
    try out.print("a record: {d} bytes of JSON\n\n", .{try recordBytes(gpa, io)});

    try out.print("Callers, output thrown away ({d} records per producer)\n", .{per_producer});
    try header(out);
    for ([_]log.Mode{ .sync, .{ .queued = .{} }, .{ .queued = .{ .overflow = .block } } }) |mode| {
        for ([_]usize{ 1, 4, 8 }) |producers| {
            try report(out, gpa, io, .{ .mode = mode, .producers = producers });
        }
    }

    try out.print("\nThe writer thread, 8 producers, block, a slow reader: {d} us per write\n", .{slow_write_ns / 1000});
    try header(out);
    for ([_]u32{ 32, 128, 512 }) |batch_size| {
        try report(out, gpa, io, .{
            .mode = .{ .queued = .{ .batch_size = batch_size, .overflow = .block } },
            .producers = 8,
            .write_ns = slow_write_ns,
        });
    }

    try out.print("\nA burst: 8 producers x {d} records, drop_new, a stuck reader: {d} ms per write\n", .{ burst, stuck_write_ns / std.time.ns_per_ms });
    try header(out);
    for ([_]u32{ 1024, 4096, 16384 }) |capacity| {
        try report(out, gpa, io, .{
            .mode = .{ .queued = .{ .capacity = capacity } },
            .producers = 8,
            .records = burst,
            .write_ns = stuck_write_ns,
        });
    }
}

const per_producer = 100_000;
const slow_write_ns = 20 * std.time.ns_per_us;
const burst = 2000;
const stuck_write_ns = std.time.ns_per_ms;

const Scenario = struct {
    mode: log.Mode,
    producers: usize,
    records: usize = per_producer,
    /// What each write of the logger costs the reader.
    write_ns: u64 = 0,
};

fn header(out: *Io.Writer) !void {
    try out.print("{s:<44} {s:>12} {s:>8} {s:>8} {s:>9} {s:>10} {s:>9}\n", .{ "scenario", "records/s", "p50 ns", "p99 ns", "p99.9 ns", "max ns", "dropped" });
}

fn report(out: *Io.Writer, gpa: std.mem.Allocator, io: Io, s: Scenario) !void {
    const r = try run(gpa, io, s);
    var name_buf: [64]u8 = undefined;
    const name = switch (s.mode) {
        .sync => try std.fmt.bufPrint(&name_buf, "sync, {d} producer(s)", .{s.producers}),
        .queued => |q| try std.fmt.bufPrint(&name_buf, "queued {t}, cap {d}, batch {d}, {d} producer(s)", .{ q.overflow, q.capacity, q.batch_size, s.producers }),
    };
    try out.print("{s:<44} {d:>12.0} {d:>8} {d:>8} {d:>9} {d:>10} {d:>8.2}%\n", .{
        name, r.per_second, r.p50, r.p99, r.p999, r.max, r.dropped_percent,
    });
    try out.flush();
}

const Result = struct {
    per_second: f64,
    p50: u64,
    p99: u64,
    p999: u64,
    max: u64,
    dropped_percent: f64,
};

fn run(gpa: std.mem.Allocator, io: Io, s: Scenario) !Result {
    var sink: Sink = .{ .write_ns = s.write_ns, .io = io };
    const logger: log.Logger = try .init(gpa, io, .{ .mode = s.mode, .output = .{ .writer = &sink.writer } });
    defer logger.deinit();
    const latencies = try gpa.alloc(u64, s.producers * s.records);
    defer gpa.free(latencies);

    const start = Io.Clock.awake.now(io);
    {
        var threads: [8]std.Thread = undefined;
        var spawned: usize = 0;
        defer for (threads[0..spawned]) |t| t.join();
        for (threads[0..s.producers], 0..) |*t, p| {
            t.* = try std.Thread.spawn(.{}, produce, .{ logger, io, p, latencies[p * s.records ..][0..s.records] });
            spawned += 1;
        }
    }
    try logger.flush(.none);
    const elapsed = start.durationTo(Io.Clock.awake.now(io));

    std.mem.sort(u64, latencies, {}, std.sort.asc(u64));
    const stats = logger.stats();
    const total: f64 = @floatFromInt(latencies.len);
    return .{
        .per_second = total / (@as(f64, @floatFromInt(elapsed.nanoseconds)) / std.time.ns_per_s),
        .p50 = percentile(latencies, 50, 100),
        .p99 = percentile(latencies, 99, 100),
        .p999 = percentile(latencies, 999, 1000),
        .max = latencies[latencies.len - 1],
        .dropped_percent = @as(f64, @floatFromInt(stats.dropped.queue_full)) * 100 / total,
    };
}

fn percentile(sorted: []const u64, part: usize, whole: usize) u64 {
    return sorted[(sorted.len - 1) * part / whole];
}

/// A typical service record, and the time each call takes.
fn produce(logger: log.Logger, io: Io, producer: usize, latencies: []u64) void {
    for (latencies, 0..) |*latency, i| {
        const t0 = Io.Clock.awake.now(io);
        logger.info("Request handled", .{
            .method = "GET",
            .path = "/api/v1/users/42/orders",
            .status = 200,
            .duration_ms = 12.5,
            .producer = producer,
            .seq = i,
        });
        latency.* = @intCast(t0.durationTo(Io.Clock.awake.now(io)).nanoseconds);
    }
}

fn recordBytes(gpa: std.mem.Allocator, io: Io) !usize {
    var sink: Sink = .{ .write_ns = 0, .io = io };
    const logger: log.Logger = try .init(gpa, io, .{ .output = .{ .writer = &sink.writer } });
    defer logger.deinit();
    var one: [1]u64 = undefined;
    produce(logger, io, 0, &one);
    return sink.bytes;
}

/// Throws the records away, after `write_ns` of busy waiting per write:
/// a reader that takes that long for each write.
const Sink = struct {
    write_ns: u64,
    io: Io,
    bytes: usize = 0,
    writer: Io.Writer = .{ .buffer = &.{}, .vtable = &.{ .drain = drain } },

    fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const sink: *Sink = @alignCast(@fieldParentPtr("writer", w));
        if (sink.write_ns > 0) {
            const start = Io.Clock.awake.now(sink.io);
            while (start.durationTo(Io.Clock.awake.now(sink.io)).nanoseconds < sink.write_ns) std.atomic.spinLoopHint();
        }
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| n += bytes.len;
        n += data[data.len - 1].len * splat;
        sink.bytes += n;
        return n;
    }
};
