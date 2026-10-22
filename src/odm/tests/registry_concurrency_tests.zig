//! Tests of odm.Registry under concurrent load on odm.testing.FakeDriver:
//! pings in flight while connections are replaced, drains that run out,
//! and a shutdown in the middle of it. Every replacement brings new
//! settings, since the same ones change nothing. Every wait is a loop on
//! the .awake clock, so that a call that never returns fails the test.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const odm = @import("../root.zig");
const FakeDriver = odm.testing.FakeDriver;
const Registry = odm.Registry;

const ids = [_][]const u8{ "c1", "c2" };

/// The pings of many tasks for a while, and what they got.
const Load = struct {
    registry: *Registry,
    until: Io.Timestamp,
    /// The errors that a ping may get in the test.
    allowed: []const anyerror,
    pings: std.atomic.Value(usize) = .init(0),
    errors: std.atomic.Value(usize) = .init(0),
    unexpected: std.atomic.Value(usize) = .init(0),
    /// The tasks that are done.
    done: std.atomic.Value(usize) = .init(0),

    fn ping(load: *Load, io: Io) void {
        defer _ = load.done.fetchAdd(1, .release);
        while (Io.Clock.awake.now(io).nanoseconds < load.until.nanoseconds) {
            for (ids) |id| {
                if (load.registry.ping(io, .root, id)) |_| {
                    _ = load.pings.fetchAdd(1, .monotonic);
                } else |err| {
                    _ = load.errors.fetchAdd(1, .monotonic);
                    if (!isAllowed(load.allowed, err)) {
                        if (load.unexpected.fetchAdd(1, .monotonic) == 0) std.debug.print("unexpected error of ping: {t}\n", .{err});
                    }
                }
            }
            // A breath between rounds keeps the journal of the fake small.
            io.sleep(.fromMicroseconds(200), .awake) catch return;
        }
    }
};

fn isAllowed(allowed: []const anyerror, err: anyerror) bool {
    for (allowed) |x| {
        if (x == err) return true;
    }
    return false;
}

/// Five replacements of each connection, each with new settings.
const Replacer = struct {
    registry: *Registry,
    allowed: []const anyerror,
    replaced: std.atomic.Value(usize) = .init(0),
    unexpected: std.atomic.Value(usize) = .init(0),
    done: std.atomic.Value(bool) = .init(false),

    fn run(re: *Replacer, io: Io) void {
        defer re.done.store(true, .release);
        for (1..6) |round| {
            for (ids) |id| {
                var buffer: [32]u8 = undefined;
                const uri = std.fmt.bufPrint(&buffer, "fake://{s}-{d}", .{ id, round }) catch unreachable;
                if (re.registry.replaceConnection(io, .root, id, .{ .uri = uri })) |_| {
                    _ = re.replaced.fetchAdd(1, .monotonic);
                } else |err| {
                    if (!isAllowed(re.allowed, err)) {
                        if (re.unexpected.fetchAdd(1, .monotonic) == 0) std.debug.print("unexpected error of replaceConnection: {t}\n", .{err});
                    }
                }
            }
            io.sleep(.fromMilliseconds(20), .awake) catch return;
        }
    }
};

/// Until `n` tasks of `counter` are done; error.Timeout after 10 s.
fn waitCount(io: Io, counter: *std.atomic.Value(usize), n: usize) !void {
    const give_up = Io.Clock.awake.now(io).addDuration(.fromSeconds(10));
    while (counter.load(.acquire) < n) {
        if (Io.Clock.awake.now(io).nanoseconds >= give_up.nanoseconds) {
            std.debug.print("{d} of {d} tasks were done after 10 s\n", .{ counter.load(.acquire), n });
            return error.Timeout;
        }
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}

fn waitFlag(io: Io, flag: *std.atomic.Value(bool)) !void {
    const give_up = Io.Clock.awake.now(io).addDuration(.fromSeconds(10));
    while (!flag.load(.acquire)) {
        if (Io.Clock.awake.now(io).nanoseconds >= give_up.nanoseconds) {
            std.debug.print("a task was not done after 10 s\n", .{});
            return error.Timeout;
        }
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}

/// Until the fake has freed `n` clients; error.Timeout after 10 s.
fn waitFreed(io: Io, fake: *FakeDriver, n: usize) !void {
    const give_up = Io.Clock.awake.now(io).addDuration(.fromSeconds(10));
    while (fake.counts(io).freed < n) {
        if (Io.Clock.awake.now(io).nanoseconds >= give_up.nanoseconds) return error.Timeout;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}

fn register(registry: *Registry, io: Io) !void {
    for (ids) |id| {
        var buffer: [32]u8 = undefined;
        try registry.registerConnection(io, id, .{ .uri = try std.fmt.bufPrint(&buffer, "fake://{s}-0", .{id}) });
        try registry.connect(io, .root, id);
    }
}

test "replacements while pings are in flight" {
    const io = testing.io;
    var fake: FakeDriver = .init(testing.allocator);
    defer fake.deinit();
    {
        var registry: Registry = .init(testing.allocator, io, fake.driver(), .{});
        defer registry.deinit(io);
        try register(&registry, io);
        var load: Load = .{
            .registry = &registry,
            .until = Io.Clock.awake.now(io).addDuration(.fromMilliseconds(300)),
            .allowed = &.{},
        };
        var replacer: Replacer = .{ .registry = &registry, .allowed = &.{} };
        {
            var group: Io.Group = .init;
            defer group.cancel(io);
            for (0..16) |_| try group.concurrent(io, Load.ping, .{ &load, io });
            try group.concurrent(io, Replacer.run, .{ &replacer, io });
            try waitCount(io, &load.done, 16);
            try waitFlag(io, &replacer.done);
        }
        try testing.expectEqual(@as(usize, 0), load.unexpected.load(.monotonic));
        try testing.expectEqual(@as(usize, 0), load.errors.load(.monotonic));
        try testing.expectEqual(@as(usize, 0), replacer.unexpected.load(.monotonic));
        try testing.expectEqual(@as(usize, 10), replacer.replaced.load(.monotonic));
        try testing.expect(load.pings.load(.monotonic) > 0);
        for (ids) |id| try testing.expectEqual(@as(u64, 6), (try registry.connectionStats(io, id)).generation);
        const s = registry.stats(io);
        try testing.expectEqual(@as(usize, 0), s.leases);
        try testing.expectEqual(@as(usize, 0), s.draining);
        try testing.expectEqual(@as(usize, 0), s.forced);
        // Each old generation was opened, closed and freed exactly once.
        const counts = fake.counts(io);
        try testing.expectEqual(@as(usize, 12), counts.opened);
        try testing.expectEqual(@as(usize, 12), counts.connected);
        try testing.expectEqual(@as(usize, 10), counts.closed);
        try testing.expectEqual(@as(usize, 10), counts.close_calls);
        try testing.expectEqual(@as(usize, 10), counts.freed);
    }
    const counts = fake.counts(io);
    try testing.expectEqual(@as(usize, 12), counts.closed);
    try testing.expectEqual(@as(usize, 12), counts.close_calls);
    try testing.expectEqual(@as(usize, 12), counts.freed);
}

fn pingHeld(registry: *Registry, io: Io, result: *std.atomic.Value(usize), done: *std.atomic.Value(usize)) void {
    defer _ = done.fetchAdd(1, .release);
    registry.ping(io, .root, "c1") catch |err| switch (err) {
        error.Closed => _ = result.fetchAdd(1, .monotonic),
        else => std.debug.print("unexpected error of a held ping: {t}\n", .{err}),
    };
}

test "a drain that runs out while gates hold pings" {
    const io = testing.io;
    var fake: FakeDriver = .init(testing.allocator);
    defer fake.deinit();
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;
    {
        var registry: Registry = .init(testing.allocator, io, fake.driver(), .{ .drain_timeout = .fromMilliseconds(100) });
        defer registry.deinit(io);
        var gate: FakeDriver.Gate = .{};
        defer gate.open(io);
        try fake.plan("fake://held", .{ .gate = &gate });
        try registry.registerConnection(io, "c1", .{ .uri = "fake://held" });
        try registry.connect(io, .root, "c1");
        var closed: std.atomic.Value(usize) = .init(0);
        var done: std.atomic.Value(usize) = .init(0);
        {
            var group: Io.Group = .init;
            defer group.cancel(io);
            for (0..8) |_| try group.concurrent(io, pingHeld, .{ &registry, io, &closed, &done });
            try gate.waitFor(io, 8);
            try testing.expectEqual(@as(usize, 8), (try registry.connectionStats(io, "c1")).leases);
            const start = Io.Clock.awake.now(io);
            try registry.replaceConnection(io, .root, "c1", .{ .uri = "fake://next" });
            try testing.expect(start.durationTo(Io.Clock.awake.now(io)).nanoseconds >= 100 * std.time.ns_per_ms);
            try waitCount(io, &done, 8);
        }
        // Every holder got Closed, and the last one freed the memory.
        try testing.expectEqual(@as(usize, 8), closed.load(.monotonic));
        try waitFreed(io, &fake, 1);
        const s = registry.stats(io);
        try testing.expectEqual(@as(usize, 1), s.forced);
        try testing.expectEqual(@as(usize, 0), s.leases);
        try testing.expectEqual(@as(usize, 0), s.draining);
        const counts = fake.counts(io);
        try testing.expectEqual(@as(usize, 1), counts.closed);
        try testing.expectEqual(@as(usize, 1), counts.freed);
        try testing.expectEqual(@as(u64, 2), (try registry.connectionStats(io, "c1")).generation);
    }
    const counts = fake.counts(io);
    try testing.expectEqual(counts.opened, counts.freed);
    try testing.expectEqual(counts.opened, counts.close_calls);
}

test "shutdown in the middle of it" {
    const io = testing.io;
    var fake: FakeDriver = .init(testing.allocator);
    defer fake.deinit();
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;
    {
        var registry: Registry = .init(testing.allocator, io, fake.driver(), .{});
        defer registry.deinit(io);
        try register(&registry, io);
        var load: Load = .{
            .registry = &registry,
            .until = Io.Clock.awake.now(io).addDuration(.fromMilliseconds(300)),
            // A ping after the shutdown began, or in a generation that it
            // closed by force.
            .allowed = &.{ error.ShuttingDown, error.Closed },
        };
        var replacer: Replacer = .{ .registry = &registry, .allowed = &.{error.ShuttingDown} };
        var result: odm.ShutdownError!void = {};
        {
            var group: Io.Group = .init;
            defer group.cancel(io);
            for (0..16) |_| try group.concurrent(io, Load.ping, .{ &load, io });
            try group.concurrent(io, Replacer.run, .{ &replacer, io });
            try io.sleep(.fromMilliseconds(100), .awake);
            result = registry.shutdown(io, .fromNow(io, .{ .raw = .fromSeconds(1), .clock = .awake }));
            try waitCount(io, &load.done, 16);
            try waitFlag(io, &replacer.done);
        }
        try testing.expectEqual(@as(usize, 0), load.unexpected.load(.monotonic));
        try testing.expectEqual(@as(usize, 0), replacer.unexpected.load(.monotonic));
        const s = registry.stats(io);
        // ShutdownTimeout only if leases were left at the deadline: then
        // their generations were closed by force.
        if (result) |_| {
            try testing.expectEqual(@as(usize, 0), s.forced);
        } else |err| {
            try testing.expectEqual(error.ShutdownTimeout, err);
            try testing.expect(s.forced > 0);
        }
        try testing.expectEqual(@as(usize, 0), s.leases);
        try testing.expectError(error.ShuttingDown, registry.ping(io, .root, "c1"));
    }
    // Every generation was opened, closed and freed exactly once.
    const counts = fake.counts(io);
    try testing.expectEqual(counts.opened, counts.closed);
    try testing.expectEqual(counts.opened, counts.close_calls);
    try testing.expectEqual(counts.opened, counts.freed);
}
