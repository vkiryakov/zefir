//! The benchmark of zefir-nats: publishing, publishing to a subscriber,
//! and request/reply at several concurrencies, against the plain server
//! of the repository's docker-compose.yml, on zio with one executor and
//! with four. `zig build bench` in tests/nats starts the server and runs
//! it, built with ReleaseFast unless `-Dbench-optimize` says otherwise.
//!
//! The numbers depend on the machine, the network path to the server (on
//! macOS, Docker Desktop forwards the port through its VM) and the
//! server: they are for comparing builds and runtimes, not a promise. A
//! panic prints its message and exits with code 3 instead of aborting.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const nats = @import("nats");
const zio = @import("zio");

pub const panic = std.debug.FullPanic(exitOnPanic);

fn exitOnPanic(message: []const u8, _: ?usize) noreturn {
    std.debug.print("panic: {s}\n", .{message});
    std.process.exit(3);
}

const server = "nats://127.0.0.1:14222";
const gpa = std.heap.smp_allocator;
const a_minute: Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(60), .clock = .awake } };

pub fn main(init: std.process.Init) !void {
    var buffer: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writer(init.io, &buffer);
    const out = &stdout.interface;
    try out.print("zefir-nats benchmark: {t} build, {t} {t}, server {s}\n\n", .{ builtin.mode, builtin.os.tag, builtin.cpu.arch, server });
    try out.flush();
    for ([_]u8{ 1, 4 }) |executors| {
        const runtime = try zio.Runtime.init(gpa, .{ .executors = .exact(executors) });
        defer runtime.deinit();
        const io = runtime.io();
        try out.print("zio, {d} {s}\n", .{ executors, if (executors == 1) "executor" else "executors" });
        try out.print("  {s:<34} {s:>10} {s:>14} {s:>10}\n", .{ "scenario", "messages", "messages/s", "MB/s" });
        try out.flush();
        for ([_]struct { usize, usize }{ .{ 16, 1_000_000 }, .{ 128, 1_000_000 }, .{ 1024, 300_000 }, .{ 16 * 1024, 30_000 } }) |case| {
            const result = try publishOnly(io, case[0], case[1]);
            try printThroughput(out, "publish", case[0], case[1], result);
        }
        for ([_]struct { usize, usize }{ .{ 16, 300_000 }, .{ 128, 300_000 }, .{ 1024, 100_000 } }) |case| {
            const result = try publishToSubscriber(io, case[0], case[1]);
            try printThroughput(out, "publish to a subscriber", case[0], case[1], result);
        }
        try out.print("  {s:<34} {s:>10} {s:>14} {s:>10} {s:>10} {s:>10}\n", .{ "request/reply, 16 B", "requests", "requests/s", "p50 µs", "p99 µs", "max µs" });
        for ([_]usize{ 1, 16, 256 }) |concurrency| {
            const total: usize = if (concurrency == 1) 10_000 else 50_000;
            try requestReply(io, out, concurrency, total);
        }
        try out.print("\n", .{});
        try out.flush();
    }
}

fn printThroughput(out: *Io.Writer, scenario: []const u8, size: usize, count: usize, took: Io.Duration) !void {
    const seconds = @as(f64, @floatFromInt(took.nanoseconds)) / std.time.ns_per_s;
    const rate = @as(f64, @floatFromInt(count)) / seconds;
    const megabytes = rate * @as(f64, @floatFromInt(size)) / 1_000_000;
    var label: [48]u8 = undefined;
    try out.print("  {s:<34} {d:>10} {d:>14.0} {d:>10.1}\n", .{ try std.fmt.bufPrint(&label, "{s}, {d} B", .{ scenario, size }), count, rate, megabytes });
    try out.flush();
}

/// Connects `client` in place: once connected, a client must not move.
fn connect(client: *nats.Client, io: Io, name: []const u8) !void {
    client.* = try .init(gpa, io, .{ .servers = &.{server}, .name = name });
    errdefer client.deinit();
    try client.connect();
}

/// Publishes `count` messages of `size` bytes, until the server has them
/// all; no one subscribes.
fn publishOnly(io: Io, size: usize, count: usize) !Io.Duration {
    var client: nats.Client = undefined;
    try connect(&client, io, "bench-publisher");
    defer client.deinit();
    const payload = try gpa.alloc(u8, size);
    defer gpa.free(payload);
    @memset(payload, 'x');
    const start = Io.Clock.awake.now(io);
    for (0..count) |_| try client.publish("bench.publish", payload);
    try client.flush(.{ .timeout = a_minute });
    return start.durationTo(Io.Clock.awake.now(io));
}

/// Takes `count` messages from `sub`; fails after a minute.
fn receive(sub: *nats.Subscription, count: usize) !void {
    for (0..count) |_| {
        var msg = (try sub.next(.{ .timeout = a_minute })) orelse return error.SubscriptionEnded;
        msg.deinit();
    }
}

/// Publishes `count` messages of `size` bytes from one client to a
/// subscription of another, until the subscriber has taken them all.
fn publishToSubscriber(io: Io, size: usize, count: usize) !Io.Duration {
    var subscriber: nats.Client = undefined;
    try connect(&subscriber, io, "bench-subscriber");
    defer subscriber.deinit();
    const sub = try subscriber.subscribe("bench.pubsub", .{ .pending = .{ .messages = @intCast(count), .bytes = 1024 * 1024 * 1024 } });
    defer sub.deinit();
    try subscriber.flush(.{});
    var publisher: nats.Client = undefined;
    try connect(&publisher, io, "bench-publisher");
    defer publisher.deinit();
    const payload = try gpa.alloc(u8, size);
    defer gpa.free(payload);
    @memset(payload, 'x');

    var reader = try io.concurrent(receive, .{ sub, count });
    defer reader.cancel(io) catch {};
    const start = Io.Clock.awake.now(io);
    for (0..count) |_| try publisher.publish("bench.pubsub", payload);
    try publisher.flush(.{ .timeout = a_minute });
    try reader.await(io);
    const took = start.durationTo(Io.Clock.awake.now(io));
    if (sub.stats().dropped != 0) return error.MessagesDropped;
    return took;
}

fn answer(client: *nats.Client, sub: *nats.Subscription) !void {
    while (true) {
        var msg = (try sub.next(.{})) orelse return;
        defer msg.deinit();
        try client.respond(&msg, msg.payload);
    }
}

/// Sends `latencies.len` requests one after the other and records how
/// long each took, in nanoseconds.
fn requestLoop(io: Io, client: *nats.Client, latencies: []u64) anyerror!void {
    for (latencies) |*latency| {
        const start = Io.Clock.awake.now(io);
        var reply = try client.request("bench.rr", "0123456789abcdef", .{ .timeout = a_minute });
        reply.deinit();
        latency.* = @intCast(start.durationTo(Io.Clock.awake.now(io)).nanoseconds);
    }
}

/// `total` requests from `concurrency` tasks of one client to one
/// responder, a client of its own.
fn requestReply(io: Io, out: *Io.Writer, concurrency: usize, total: usize) !void {
    var responder: nats.Client = undefined;
    try connect(&responder, io, "bench-responder");
    defer responder.deinit();
    const sub = try responder.subscribe("bench.rr", .{ .pending = .{ .messages = @intCast(total), .bytes = 256 * 1024 * 1024 } });
    defer sub.deinit();
    try responder.flush(.{});
    var answering = try io.concurrent(answer, .{ &responder, sub });
    defer answering.cancel(io) catch {};
    var requester: nats.Client = undefined;
    try connect(&requester, io, "bench-requester");
    defer requester.deinit();

    const latencies = try gpa.alloc(u64, total);
    defer gpa.free(latencies);
    const each = total / concurrency;
    const tasks = try gpa.alloc(Io.Future(anyerror!void), concurrency);
    defer gpa.free(tasks);
    var started: usize = 0;
    defer for (tasks[0..started]) |*task| task.cancel(io) catch {};
    const start = Io.Clock.awake.now(io);
    for (tasks, 0..) |*task, i| {
        task.* = try io.concurrent(requestLoop, .{ io, &requester, latencies[i * each ..][0..each] });
        started += 1;
    }
    for (tasks) |*task| try task.await(io);
    const took = start.durationTo(Io.Clock.awake.now(io));
    const done = latencies[0 .. each * concurrency];
    std.mem.sortUnstable(u64, done, {}, std.sort.asc(u64));
    const seconds = @as(f64, @floatFromInt(took.nanoseconds)) / std.time.ns_per_s;
    var label: [48]u8 = undefined;
    try out.print("  {s:<34} {d:>10} {d:>14.0} {d:>10} {d:>10} {d:>10}\n", .{
        try std.fmt.bufPrint(&label, "{d} at a time", .{concurrency}),
        done.len,
        @as(f64, @floatFromInt(done.len)) / seconds,
        done[done.len / 2] / std.time.ns_per_us,
        done[done.len * 99 / 100] / std.time.ns_per_us,
        done[done.len - 1] / std.time.ns_per_us,
    });
    try out.flush();
}
