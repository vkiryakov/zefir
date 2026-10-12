//! Benchmarks for zefir-log. `zig build bench` builds them with ReleaseFast
//! and prints the environment, then one table per question: records per
//! second, the caller's time per record (two clock reads included), the
//! records dropped, the process's CPU time per record and the memory the
//! queue takes. Unless a table says otherwise, the records go to a writer
//! that throws them away, so the numbers measure the logger rather than a
//! terminal; a "slow reader" adds a fixed cost to every write the logger
//! makes. The numbers depend on the machine.

const std = @import("std");
const builtin = @import("builtin");
const core = @import("core");
const log = @import("log");

const Io = std.Io;
const posix = builtin.os.tag != .windows;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var counting: std.testing.FailingAllocator = .init(init.gpa, .{});
    const gpa = counting.allocator();
    var stdout_buffer: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(io, &stdout_buffer);
    const out = &stdout.interface;
    defer out.flush() catch {};
    var bench: Bench = .{ .gpa = gpa, .io = io, .out = out, .counting = &counting };

    try out.print("zig {s}, {t}-{t}, {s}, {t}, {d} CPUs\n", .{
        builtin.zig_version_string,       builtin.cpu.arch, builtin.os.tag, builtin.cpu.model.name, builtin.mode,
        std.Thread.getCpuCount() catch 0,
    });
    for (std.enums.values(Record)) |record| {
        try out.print("a {t} record: {d} bytes of JSON\n", .{ record, try recordBytes(gpa, io, record) });
    }

    try bench.table("Modes and producers ({d} records per producer)", .{per_producer});
    for ([_]log.Mode{ .sync, .{ .queued = .{} }, .{ .queued = .{ .overflow = .block } } }) |mode| {
        for ([_]usize{ 1, 2, 4, 8, 16 }) |producers| try bench.report(.{ .mode = mode, .producers = producers });
    }

    try bench.table("Records: queued drop_new, 4 producers", .{});
    for (std.enums.values(Record)) |record| {
        try bench.report(.{ .mode = .{ .queued = .{} }, .producers = 4, .record = record });
    }

    if (posix) {
        try bench.table("Outputs: 4 producers, writes through a 64 KiB buffer (sync: one write call per record)", .{});
        for ([_]log.Mode{ .sync, .{ .queued = .{} } }) |mode| {
            for ([_]Output{ .discard, .dev_null, .pipe }) |output| {
                try bench.report(.{ .mode = mode, .producers = 4, .output = output });
            }
        }
    }

    try bench.table("Batches: queued block, 8 producers, a slow reader taking {d} us per write", .{slow_write_ns / std.time.ns_per_us});
    for ([_]u32{ 32, 128, 512 }) |batch_size| {
        try bench.report(.{ .mode = .{ .queued = .{ .batch_size = batch_size, .overflow = .block } }, .producers = 8, .write_ns = slow_write_ns });
    }

    try bench.table("A burst: 8 producers x {d} records, queued drop_new, a stuck reader taking {d} ms per write", .{ burst, stuck_write_ns / std.time.ns_per_ms });
    for ([_]u32{ 1024, 4096, 16384 }) |capacity| {
        try bench.report(.{ .mode = .{ .queued = .{ .capacity = capacity } }, .producers = 8, .records = burst, .write_ns = stuck_write_ns });
    }

    try out.print("\nallocations after init, all scenarios: {d}\n", .{bench.allocations_after_init});
}

const per_producer = 100_000;
const slow_write_ns = 20 * std.time.ns_per_us;
const burst = 2000;
const stuck_write_ns = std.time.ns_per_ms;

const Record = enum {
    /// A message and nothing else.
    tiny,
    /// A request log: five fields.
    typical,
    /// The typical record with the call site and the trace ids.
    traced,
    /// The typical record with a 1 KiB field.
    large,
};

const Output = enum {
    /// A writer that throws the records away.
    discard,
    /// /dev/null through a file writer: one write call per batch.
    dev_null,
    /// A pipe that another thread reads and throws away.
    pipe,
};

const Scenario = struct {
    mode: log.Mode,
    producers: usize,
    records: usize = per_producer,
    record: Record = .typical,
    output: Output = .discard,
    /// What each write of the logger costs the reader.
    write_ns: u64 = 0,
};

const Result = struct {
    per_second: f64,
    p50: u64,
    p95: u64,
    p99: u64,
    p999: u64,
    max: u64,
    dropped_percent: f64,
    /// User and system time of the whole process, per record.
    cpu_ns: u64,
};

const Bench = struct {
    gpa: std.mem.Allocator,
    io: Io,
    out: *Io.Writer,
    counting: *std.testing.FailingAllocator,
    allocations_after_init: usize = 0,

    fn table(b: *Bench, comptime title: []const u8, args: anytype) !void {
        try b.out.print("\n" ++ title ++ "\n", args);
        try b.out.print("{s:<74} {s:>11} {s:>7} {s:>7} {s:>7} {s:>8} {s:>9} {s:>8} {s:>7} {s:>6}\n", .{
            "scenario", "records/s", "p50 ns", "p95 ns", "p99 ns", "p99.9 ns", "max ns", "dropped", "CPU ns", "MiB",
        });
    }

    fn report(b: *Bench, s: Scenario) !void {
        const r = try b.run(s);
        var name_buf: [96]u8 = undefined;
        const name = switch (s.mode) {
            .sync => try std.fmt.bufPrint(&name_buf, "sync, {d} producer(s), {t}, {t}", .{ s.producers, s.record, s.output }),
            .queued => |q| try std.fmt.bufPrint(&name_buf, "queued {t}, cap {d}, batch {d}, {d} producer(s), {t}, {t}", .{ q.overflow, q.capacity, q.batch_size, s.producers, s.record, s.output }),
        };
        const options: log.Options = .{ .mode = s.mode };
        const mib = @as(f64, @floatFromInt(options.queueBytes())) / (1024 * 1024);
        try b.out.print("{s:<74} {d:>11.0} {d:>7} {d:>7} {d:>7} {d:>8} {d:>9} {d:>7.2}% {d:>7} {d:>6.1}\n", .{
            name, r.per_second, r.p50, r.p95, r.p99, r.p999, r.max, r.dropped_percent, r.cpu_ns, mib,
        });
        try b.out.flush();
    }

    fn run(b: *Bench, s: Scenario) !Result {
        const io = b.io;
        var sink: Sink = .{ .write_ns = s.write_ns, .io = io };
        var file_buffer: [64 * 1024]u8 = undefined;
        var target: Target = try .open(io, s.output, &sink);
        target.point(io, &file_buffer);
        defer target.close(io);
        const logger: log.Logger = try .init(b.gpa, io, .{ .mode = s.mode, .output = .{ .writer = target.writer } });
        defer logger.deinit();
        const latencies = try b.gpa.alloc(u64, s.producers * s.records);
        defer b.gpa.free(latencies);
        const handle = if (s.record == .traced) logger.withContext(tracedContext()) else logger;
        const allocations = b.counting.allocations;

        const cpu_start = cpuNanoseconds();
        const start = Io.Clock.awake.now(io);
        {
            var threads: [16]std.Thread = undefined;
            var spawned: usize = 0;
            defer for (threads[0..spawned]) |t| t.join();
            for (threads[0..s.producers], 0..) |*t, p| {
                t.* = try std.Thread.spawn(.{}, produce, .{ handle, io, s.record, p, latencies[p * s.records ..][0..s.records] });
                spawned += 1;
            }
        }
        try logger.flush(.none);
        const elapsed = start.durationTo(Io.Clock.awake.now(io));
        const cpu = cpuNanoseconds() - cpu_start;
        b.allocations_after_init += b.counting.allocations - allocations;

        std.mem.sort(u64, latencies, {}, std.sort.asc(u64));
        const stats = logger.stats();
        const total: f64 = @floatFromInt(latencies.len);
        return .{
            .per_second = total / (@as(f64, @floatFromInt(elapsed.nanoseconds)) / std.time.ns_per_s),
            .p50 = percentile(latencies, 50, 100),
            .p95 = percentile(latencies, 95, 100),
            .p99 = percentile(latencies, 99, 100),
            .p999 = percentile(latencies, 999, 1000),
            .max = latencies[latencies.len - 1],
            .dropped_percent = @as(f64, @floatFromInt(stats.dropped.queue_full)) * 100 / total,
            .cpu_ns = @intFromFloat(@as(f64, @floatFromInt(cpu)) / total),
        };
    }
};

fn percentile(sorted: []const u64, part: usize, whole: usize) u64 {
    return sorted[(sorted.len - 1) * part / whole];
}

/// The process's user and system time; 0 where it cannot be read.
fn cpuNanoseconds() u64 {
    if (posix) {
        const usage = std.posix.getrusage(std.posix.rusage.SELF);
        const us = (usage.utime.sec + usage.stime.sec) * std.time.us_per_s + usage.utime.usec + usage.stime.usec;
        return @as(u64, @intCast(us)) * std.time.ns_per_us;
    } else return 0;
}

fn tracedContext() core.Context {
    const trace = core.w3c.parseTraceparent("00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01") catch unreachable; // a valid header
    return core.Context.root.withTrace(trace);
}

const large_body: [1024]u8 = @splat('b');

/// One record of each kind per call, and the time each call takes.
fn produce(logger: log.Logger, io: Io, record: Record, producer: usize, latencies: []u64) void {
    switch (record) {
        inline else => |kind| for (latencies, 0..) |*latency, i| {
            const t0 = Io.Clock.awake.now(io);
            logOne(kind, logger, producer, i);
            latency.* = @intCast(t0.durationTo(Io.Clock.awake.now(io)).nanoseconds);
        },
    }
}

fn logOne(comptime kind: Record, logger: log.Logger, producer: usize, i: usize) void {
    switch (kind) {
        .tiny => logger.info("Tick", .{}),
        .typical => logger.info("Request handled", .{ .method = "GET", .path = "/api/v1/users/42/orders", .status = 200, .duration_ms = 12.5, .producer = producer, .seq = i }),
        .traced => logger.info("Request handled", .{ .src = @src(), .method = "GET", .path = "/api/v1/users/42/orders", .status = 200, .duration_ms = 12.5, .producer = producer, .seq = i }),
        .large => logger.info("Request handled", .{ .method = "GET", .path = "/api/v1/users/42/orders", .status = 200, .body = @as([]const u8, &large_body), .producer = producer, .seq = i }),
    }
}

fn recordBytes(gpa: std.mem.Allocator, io: Io, record: Record) !usize {
    var sink: Sink = .{ .write_ns = 0, .io = io };
    const logger: log.Logger = try .init(gpa, io, .{ .output = .{ .writer = &sink.writer } });
    defer logger.deinit();
    const handle = if (record == .traced) logger.withContext(tracedContext()) else logger;
    var one: [1]u64 = undefined;
    produce(handle, io, record, 0, &one);
    return sink.bytes;
}

/// Where a scenario's records go.
const Target = struct {
    writer: *Io.Writer,
    file: ?Io.File = null,
    file_writer: Io.File.Writer = undefined,
    reader: ?std.Thread = null,

    fn open(io: Io, output: Output, sink: *Sink) !Target {
        var t: Target = .{ .writer = &sink.writer };
        if (posix) {
            switch (output) {
                .discard => {},
                .dev_null => t.file = try Io.Dir.openFileAbsolute(io, "/dev/null", .{ .mode = .write_only }),
                .pipe => {
                    const fds = try Io.Threaded.pipe2(.{});
                    const read_end: Io.File = .{ .handle = fds[0], .flags = .{ .nonblocking = false } };
                    t.file = .{ .handle = fds[1], .flags = .{ .nonblocking = false } };
                    t.reader = try std.Thread.spawn(.{}, readAll, .{ read_end, io });
                },
            }
        }
        return t;
    }

    /// The writer, once `t` stays where it is.
    fn point(t: *Target, io: Io, buffer: []u8) void {
        const file = t.file orelse return;
        t.file_writer = file.writerStreaming(io, buffer);
        t.writer = &t.file_writer.interface;
    }

    fn close(t: *Target, io: Io) void {
        if (t.file) |file| file.close(io);
        if (t.reader) |reader| reader.join();
    }
};

/// Reads `file` until its write end is closed, and throws it all away.
fn readAll(file: Io.File, io: Io) void {
    defer file.close(io);
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        _ = file.readStreaming(io, &.{&buf}) catch return;
    }
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
