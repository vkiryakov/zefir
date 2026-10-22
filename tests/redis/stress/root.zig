//! Stress tests of zefir-redis against redis-plain of the repository's
//! docker-compose.yml: 10,000 tasks at once on a pool of 32 connections, a
//! storm of cut connections through a TCP proxy, `close` with 1,000 calls
//! in flight, and a subscriber under a stream of 100,000 messages. `zig
//! build stress` runs them in Debug and in ReleaseSafe, each on zio with
//! one executor and again with four, and every test checks that the
//! client's memory comes back and that no call outlives its deadline.
//!
//! They need room: 10,000 zio tasks at once take hundreds of MB of memory,
//! and the close of 1,000 calls on as many connections takes 1,000
//! sockets, which `onZio` raises the limit of open files for.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const testing = std.testing;
const core = @import("core");
const redis = @import("redis");
const zio = @import("zio");

/// How long one scenario may take on one runtime: a call that never ends
/// fails the test instead of hanging the run.
const time_limit: Io.Duration = .fromSeconds(300);

/// Runs `scenario` on zio with one executor, then with four, each under
/// `time_limit`. The stacks of the tasks reserve 1 MiB of addresses each
/// instead of 8, as thousands of tasks run at once; the 256 KiB a stack
/// starts with is far more than a task of these tests needs.
pub fn onZio(comptime scenario: fn (Io) anyerror!void) !void {
    std.process.raiseFileDescriptorLimit();
    for ([_]u8{ 1, 4 }) |executors| {
        const runtime = try zio.Runtime.init(testing.allocator, .{
            .executors = .exact(executors),
            .stack_pool = .{ .maximum_size = 1024 * 1024, .committed_size = 256 * 1024 },
        });
        defer runtime.deinit();
        std.debug.print("  {t}, {d} executor(s)\n", .{ builtin.mode, executors });
        withinTimeLimit(runtime.io(), scenario) catch |err| {
            std.debug.print("with {d} executor(s): {t}\n", .{ executors, err });
            return err;
        };
    }
}

/// Runs `scenario` in a task of its own and cancels it when it takes
/// longer than `time_limit`.
fn withinTimeLimit(io: Io, comptime scenario: fn (Io) anyerror!void) anyerror!void {
    const Race = union(enum) {
        done: anyerror!void,
        timer: Io.Cancelable!void,
    };
    var results: [2]Race = undefined;
    var select: Io.Select(Race) = .init(io, &results);
    try select.concurrent(.done, scenario, .{io});
    select.concurrent(.timer, Io.sleep, .{ io, time_limit, .awake }) catch |err| {
        while (select.cancel()) |_| {}
        return err;
    };
    const first = try select.await();
    while (select.cancel()) |_| {}
    return switch (first) {
        .done => |result| result,
        .timer => error.TestTimedOut,
    };
}

/// An allocator that counts the bytes its child holds, now and at most.
/// It is as thread-safe as its child.
pub const CountingAllocator = struct {
    child: std.mem.Allocator,
    current: std.atomic.Value(usize) = .init(0),
    peak: std.atomic.Value(usize) = .init(0),

    pub fn allocator(c: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = c, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    /// Starts measuring the peak from what is held now; returns it.
    pub fn resetPeak(c: *CountingAllocator) usize {
        const now = c.current.load(.monotonic);
        c.peak.store(now, .monotonic);
        return now;
    }

    fn grew(c: *CountingAllocator, bytes: usize) void {
        const now = c.current.fetchAdd(bytes, .monotonic) + bytes;
        _ = c.peak.fetchMax(now, .monotonic);
    }

    fn changed(c: *CountingAllocator, old_len: usize, new_len: usize) void {
        if (new_len > old_len) c.grew(new_len - old_len) else _ = c.current.fetchSub(old_len - new_len, .monotonic);
    }

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const c: *CountingAllocator = @ptrCast(@alignCast(context));
        const memory = c.child.rawAlloc(len, alignment, ret_addr) orelse return null;
        c.grew(len);
        return memory;
    }

    fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const c: *CountingAllocator = @ptrCast(@alignCast(context));
        if (!c.child.rawResize(memory, alignment, new_len, ret_addr)) return false;
        c.changed(memory.len, new_len);
        return true;
    }

    fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const c: *CountingAllocator = @ptrCast(@alignCast(context));
        const moved = c.child.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        c.changed(memory.len, new_len);
        return moved;
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const c: *CountingAllocator = @ptrCast(@alignCast(context));
        c.child.rawFree(memory, alignment, ret_addr);
        _ = c.current.fetchSub(memory.len, .monotonic);
    }
};

/// What one connection of the client holds: its object, with the read and
/// the write buffer of 16 KiB each, and a margin for the rest.
pub const bytes_per_connection = 48 * 1024;

/// The context of a call that must end within `duration` from now.
pub fn within(io: Io, duration: Io.Duration) redis.OperationContext {
    return .of(core.Context.root.withDeadline(.after(Io.Clock.awake.now(io), duration)));
}

pub fn elapsedSince(io: Io, start: Io.Timestamp) Io.Duration {
    return start.durationTo(Io.Clock.awake.now(io));
}

/// The most memory the process has held so far, in MiB; null where the
/// system does not say (Windows).
pub fn maxRssMiB() ?usize {
    const os = builtin.os.tag;
    if (os == .windows) return null;
    const usage = std.posix.getrusage(std.posix.rusage.SELF);
    const max: usize = @intCast(usage.maxrss);
    // macOS reports bytes, Linux KiB.
    return if (os.isDarwin()) max / (1024 * 1024) else max / 1024;
}

/// Waits until `done` holds `count`, for `limit` at most: a call that never
/// ends fails the test instead of hanging it.
pub fn awaitCount(io: Io, done: *const std.atomic.Value(usize), count: usize, limit: Io.Duration) !void {
    const began = Io.Clock.awake.now(io);
    while (done.load(.acquire) < count) {
        if (elapsedSince(io, began).nanoseconds >= limit.nanoseconds) {
            std.debug.print("  {d} of {d} calls still going after {d} ms\n", .{ count - done.load(.acquire), count, limit.toMilliseconds() });
            return error.TestCallsNeverEnded;
        }
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}

/// Waits until `field` of the client's stats is `value`, for `limit` at
/// most.
pub fn awaitStats(io: Io, client: *redis.Client, comptime field: []const u8, value: usize, limit: Io.Duration) !void {
    const began = Io.Clock.awake.now(io);
    while (@field(client.stats(), field) != value) {
        if (elapsedSince(io, began).nanoseconds >= limit.nanoseconds) {
            std.debug.print("  {s} is {d}, not {d}, after {d} ms\n", .{ field, @field(client.stats(), field), value, limit.toMilliseconds() });
            return error.TestTimedOut;
        }
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}

/// A client of redis-plain at `url` with `options`, whose memory
/// `counting` counts, connected.
pub fn connected(io: Io, client: *redis.Client, counting: *CountingAllocator, options: redis.Client.Options) !void {
    client.* = try .init(counting.allocator(), io, options);
    errdefer client.deinit();
    var d: redis.Diagnostics = .{};
    client.connect(io, within(io, .fromSeconds(10)).ctx, &d) catch |err| {
        std.debug.print("  connect: {t}: {s}\n", .{ err, d.message() });
        return err;
    };
}

/// The pool at rest: every connection idle, nothing opening, no call in
/// line and no subscriber.
pub fn expectAtRest(stats: redis.Client.Stats) !void {
    try testing.expectEqual(stats.connections, stats.idle);
    try testing.expectEqual(@as(usize, 0), stats.in_use + stats.opening + stats.waiting + stats.subscribers);
}

test {
    _ = @import("load.zig");
    _ = @import("storm.zig");
    _ = @import("shutdown.zig");
    _ = @import("subscriber.zig");
}
