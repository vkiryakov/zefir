//! Tests of odm.Registry on odm.testing.FakeDriver: registering and
//! connecting connections, ping and the stats.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const core = @import("core");
const odm = @import("../root.zig");
const FakeDriver = odm.testing.FakeDriver;
const Registry = odm.Registry;

/// The result of one call of the registry in a task of its own.
const Outcome = struct {
    result: odm.Error!void = {},
    done: std.atomic.Value(bool) = .init(false),

    fn set(o: *Outcome, result: odm.Error!void) void {
        o.result = result;
        o.done.store(true, .release);
    }

    fn isDone(o: *Outcome, io: Io) bool {
        _ = io;
        return o.done.load(.acquire);
    }

    /// The result, once the call returned; error.Timeout after 5 s.
    fn wait(o: *Outcome, io: Io) !odm.Error!void {
        try eventually(io, o, isDone);
        return o.result;
    }
};

/// Until `holds(arg, io)`, looking every millisecond; error.Timeout after
/// 5 s on the .awake clock, so that a call that never returns fails the
/// test.
fn eventually(io: Io, arg: anytype, comptime holds: fn (@TypeOf(arg), Io) bool) !void {
    const give_up = Io.Clock.awake.now(io).addDuration(.fromSeconds(5));
    while (!holds(arg, io)) {
        if (Io.Clock.awake.now(io).nanoseconds >= give_up.nanoseconds) {
            std.debug.print("the registry did not get there in 5 s\n", .{});
            return error.Timeout;
        }
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}

fn registerTask(o: *Outcome, r: *Registry, io: Io, id: []const u8, uri: []const u8) void {
    o.set(r.registerConnection(io, id, .{ .uri = uri }));
}

fn connectTask(o: *Outcome, r: *Registry, io: Io, ctx: core.Context, id: []const u8) void {
    o.set(r.connect(io, ctx, id));
}

fn pingTask(o: *Outcome, r: *Registry, io: Io, id: []const u8) void {
    o.set(r.ping(io, .root, id));
}

/// A connection id and the state that its stats must show.
const Expected = struct { r: *Registry, id: []const u8, state: odm.ConnectionState };

fn inState(e: Expected, io: Io) bool {
    const s = e.r.connectionStats(io, e.id) catch return false;
    return s.state == e.state;
}

fn connects(fake: *FakeDriver, io: Io) usize {
    var n: usize = 0;
    for (fake.journal(io)) |entry| {
        if (entry.call == .connect) n += 1;
    }
    return n;
}

test "register" {
    const io = testing.io;
    var fake: FakeDriver = .init(testing.allocator);
    defer fake.deinit();
    var registry: Registry = .init(testing.allocator, io, fake.driver(), .{});
    defer registry.deinit(io);

    var d: odm.Diagnostics = .{};
    try registry.registerConnection(io, "shared-1", .{ .uri = "fake://shared", .password = "secret", .diagnostics = &d });
    try testing.expectEqualStrings("", d.message());
    const s = try registry.connectionStats(io, "shared-1");
    try testing.expectEqual(odm.ConnectionState.registered, s.state);
    try testing.expectEqual(@as(u64, 1), s.generation);
    try testing.expectEqual(@as(usize, 0), s.leases);
    try testing.expectEqual(@as(usize, 0), s.draining);
    try testing.expectEqual(@as(usize, 0), s.tenants);
    try testing.expect(s.last_failure == null);
    try testing.expectEqual(odm.Client.PoolStats{ .connections = 0, .idle = 0, .in_use = 0, .waiting = 0 }, s.pool.?);
    // One client, and nothing went to the network.
    const counts = fake.counts(io);
    try testing.expectEqual(@as(usize, 1), counts.opened);
    try testing.expectEqual(@as(usize, 0), counts.connected);
    try testing.expectEqual(@as(usize, 0), fake.journal(io).len);
}

test "duplicate registration" {
    const io = testing.io;
    var fake: FakeDriver = .init(testing.allocator);
    defer fake.deinit();
    var registry: Registry = .init(testing.allocator, io, fake.driver(), .{});
    defer registry.deinit(io);

    try registry.registerConnection(io, "shared-1", .{ .uri = "fake://shared" });
    var d: odm.Diagnostics = .{};
    try testing.expectError(error.ConnectionExists, registry.registerConnection(io, "shared-1", .{ .uri = "fake://other", .diagnostics = &d }));
    try testing.expectEqualStrings("odm: connection shared-1 exists already", d.message());
    // A known id opens no client.
    try testing.expectEqual(@as(usize, 1), fake.counts(io).opened);
}

test "a bad id or a refused open registers nothing" {
    const io = testing.io;
    var fake: FakeDriver = .init(testing.allocator);
    defer fake.deinit();
    var registry: Registry = .init(testing.allocator, io, fake.driver(), .{});
    defer registry.deinit(io);

    var d: odm.Diagnostics = .{};
    try testing.expectError(error.InvalidArgument, registry.registerConnection(io, "a/b", .{ .uri = "fake://shared", .diagnostics = &d }));
    try testing.expectEqualStrings("odm: the connection id holds a byte other than A-Z a-z 0-9 _ - . :", d.message());
    try testing.expectError(error.InvalidArgument, registry.registerConnection(io, "", .{ .uri = "fake://shared" }));
    try testing.expectEqual(@as(usize, 0), fake.counts(io).opened);

    try fake.plan("fake://refused", .{ .open = error.Unsupported });
    try testing.expectError(error.Unsupported, registry.registerConnection(io, "refused", .{ .uri = "fake://refused", .diagnostics = &d }));
    try testing.expectEqualStrings("the plan of the fake refuses to open a client: Unsupported", d.message());
    try testing.expectError(error.ConnectionNotFound, registry.connectionStats(io, "refused"));
    try testing.expectError(error.ConnectionNotFound, registry.connect(io, .root, "refused"));
}

test "activate" {
    const io = testing.io;
    var fake: FakeDriver = .init(testing.allocator);
    defer fake.deinit();
    var registry: Registry = .init(testing.allocator, io, fake.driver(), .{});
    defer registry.deinit(io);

    try registry.registerConnection(io, "shared-1", .{ .uri = "fake://shared" });
    try registry.connect(io, .root, "shared-1");
    try testing.expectEqual(odm.ConnectionState.active, (try registry.connectionStats(io, "shared-1")).state);
    try testing.expectEqual(@as(usize, 1), fake.counts(io).connected);
    // An active connection needs nothing more: no call reaches the driver.
    try registry.connect(io, .root, "shared-1");
    try testing.expectEqual(@as(usize, 1), fake.counts(io).connected);
    try testing.expectEqual(@as(usize, 1), connects(&fake, io));
    try registry.ping(io, .root, "shared-1");
}

test "failed activation" {
    const io = testing.io;
    var fake: FakeDriver = .init(testing.allocator);
    defer fake.deinit();
    var registry: Registry = .init(testing.allocator, io, fake.driver(), .{});
    defer registry.deinit(io);

    try fake.plan("fake://locked", .{ .connects = &.{error.AuthenticationFailed} });
    try registry.registerConnection(io, "locked", .{ .uri = "fake://locked" });
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;
    try testing.expectError(error.AuthenticationFailed, registry.connect(io, .root, "locked"));
    const failed = try registry.connectionStats(io, "locked");
    try testing.expectEqual(odm.ConnectionState.failed, failed.state);
    try testing.expectEqual(odm.DriverError.AuthenticationFailed, failed.last_failure.?.err);
    try testing.expectEqualStrings("the plan of the fake fails this connect with AuthenticationFailed", failed.last_failure.?.message());
    // The client stays, and a connect may come again.
    try testing.expectError(error.Unavailable, registry.ping(io, .root, "locked"));
    try fake.plan("fake://locked", .{});
    try registry.connect(io, .root, "locked");
    const active = try registry.connectionStats(io, "locked");
    try testing.expectEqual(odm.ConnectionState.active, active.state);
    try testing.expectEqual(@as(u64, 1), active.generation);
    // The last failure stays for the record.
    try testing.expectEqual(odm.DriverError.AuthenticationFailed, active.last_failure.?.err);
    try testing.expectEqual(@as(usize, 1), fake.counts(io).opened);
}

test "one connection, one operation at a time" {
    const io = testing.io;
    var fake: FakeDriver = .init(testing.allocator);
    defer fake.deinit();
    var registry: Registry = .init(testing.allocator, io, fake.driver(), .{});
    defer registry.deinit(io);

    try fake.plan("fake://slow", .{ .connect_delay = .fromMilliseconds(200) });
    try registry.registerConnection(io, "slow", .{ .uri = "fake://slow" });
    var group: Io.Group = .init;
    defer group.cancel(io);
    var first: Outcome = .{};
    try group.concurrent(io, connectTask, .{ &first, &registry, io, core.Context.root, "slow" });
    try eventually(io, Expected{ .r = &registry, .id = "slow", .state = .connecting }, inState);
    // The second waits until the first is done, then has nothing to do.
    var second: Outcome = .{};
    try group.concurrent(io, connectTask, .{ &second, &registry, io, core.Context.root, "slow" });

    // A deadline passes while the call waits for its turn.
    const start = Io.Clock.awake.now(io);
    const soon = core.Context.root.withDeadline(.after(start, .fromMilliseconds(50)));
    try testing.expectError(error.DeadlineExceeded, registry.connect(io, soon, "slow"));
    try testing.expect(start.durationTo(Io.Clock.awake.now(io)).nanoseconds >= 50 * std.time.ns_per_ms);
    // And so does the cancelation of its task.
    var third: Outcome = .{};
    var task = try io.concurrent(connectTask, .{ &third, &registry, io, core.Context.root, "slow" });
    try io.sleep(.fromMilliseconds(10), .awake);
    task.cancel(io);
    try testing.expectError(error.Cancelled, third.result);
    // A canceled token ends the wait too.
    var token: core.CancellationToken = .init;
    token.cancel();
    try testing.expectError(error.Cancelled, registry.connect(io, core.Context.root.withCancellation(&token), "slow"));

    try try first.wait(io);
    try try second.wait(io);
    try testing.expectEqual(odm.ConnectionState.active, (try registry.connectionStats(io, "slow")).state);
    try testing.expectEqual(@as(usize, 1), connects(&fake, io));
    try testing.expectEqual(@as(usize, 1), fake.counts(io).connected);
}

test "ping and connectionStats take a lease for their call" {
    const io = testing.io;
    var fake: FakeDriver = .init(testing.allocator);
    defer fake.deinit();
    var registry: Registry = .init(testing.allocator, io, fake.driver(), .{});
    defer registry.deinit(io);

    var gate: FakeDriver.Gate = .{};
    try fake.plan("fake://held", .{ .gate = &gate });
    try registry.registerConnection(io, "held", .{ .uri = "fake://held" });
    try registry.connect(io, .root, "held");
    {
        var group: Io.Group = .init;
        defer group.cancel(io);
        defer gate.open(io);
        var ping: Outcome = .{};
        try group.concurrent(io, pingTask, .{ &ping, &registry, io, "held" });
        try gate.waitFor(io, 1);
        const held = try registry.connectionStats(io, "held");
        try testing.expectEqual(@as(usize, 1), held.leases);
        try testing.expectEqual(@as(usize, 1), registry.stats(io).leases);
        // The pool is the client's own count: the ping in flight, at the gate.
        try testing.expectEqual(odm.Client.PoolStats{ .connections = 1, .idle = 0, .in_use = 1, .waiting = 1 }, held.pool.?);
        gate.open(io);
        try try ping.wait(io);
    }
    try testing.expectEqual(@as(usize, 0), (try registry.connectionStats(io, "held")).leases);
    try testing.expectEqual(@as(usize, 0), registry.stats(io).leases);
    try testing.expectError(error.ConnectionNotFound, registry.connectionStats(io, "nope"));
    try testing.expectError(error.ConnectionNotFound, registry.ping(io, .root, "nope"));
}

test "stats counts connections by their state" {
    const io = testing.io;
    var fake: FakeDriver = .init(testing.allocator);
    defer fake.deinit();
    var registry: Registry = .init(testing.allocator, io, fake.driver(), .{});
    defer registry.deinit(io);

    try testing.expectEqual(Registry.Stats{
        .connections = .{ .registered = 0, .connecting = 0, .active = 0, .failed = 0, .removing = 0 },
        .draining = 0,
        .forced = 0,
        .leases = 0,
        .tenants = 0,
        .operations = 0,
        .operation_errors = 0,
    }, registry.stats(io));

    try fake.plan("fake://locked", .{ .connects = &.{error.AuthenticationFailed} });
    try fake.plan("fake://slow", .{ .connect_delay = .fromMilliseconds(300) });
    try registry.registerConnection(io, "registered", .{ .uri = "fake://a" });
    try registry.registerConnection(io, "active", .{ .uri = "fake://b" });
    try registry.connect(io, .root, "active");
    try registry.registerConnection(io, "failed", .{ .uri = "fake://locked" });
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;
    try testing.expectError(error.AuthenticationFailed, registry.connect(io, .root, "failed"));
    try registry.registerConnection(io, "connecting", .{ .uri = "fake://slow" });
    var group: Io.Group = .init;
    defer group.cancel(io);
    var slow: Outcome = .{};
    try group.concurrent(io, connectTask, .{ &slow, &registry, io, core.Context.root, "connecting" });
    try eventually(io, Expected{ .r = &registry, .id = "connecting", .state = .connecting }, inState);

    // The connect in progress holds a lease for its call.
    const s = registry.stats(io);
    try testing.expectEqual(Registry.Stats.Connections{ .registered = 1, .connecting = 1, .active = 1, .failed = 1, .removing = 0 }, s.connections);
    try testing.expectEqual(@as(usize, 1), s.leases);
    try testing.expectEqual(@as(usize, 0), s.draining);
    try testing.expectEqual(@as(usize, 0), s.forced);
    try try slow.wait(io);
    try testing.expectEqual(Registry.Stats.Connections{ .registered = 1, .connecting = 0, .active = 2, .failed = 1, .removing = 0 }, registry.stats(io).connections);
    try testing.expectEqual(@as(usize, 0), registry.stats(io).leases);
}

test "sixteen tasks register one new id at once" {
    const io = testing.io;
    var fake: FakeDriver = .init(testing.allocator);
    defer fake.deinit();
    {
        var registry: Registry = .init(testing.allocator, io, fake.driver(), .{});
        defer registry.deinit(io);
        var outcomes: [16]Outcome = @splat(.{});
        {
            var group: Io.Group = .init;
            defer group.cancel(io);
            for (&outcomes) |*o| try group.concurrent(io, registerTask, .{ o, &registry, io, "shared-1", "fake://shared" });
            for (&outcomes) |*o| (try o.wait(io)) catch {};
        }
        var registered: usize = 0;
        for (&outcomes) |*o| {
            if (o.result) |_| {
                registered += 1;
            } else |err| {
                try testing.expectEqual(error.ConnectionExists, err);
            }
        }
        try testing.expectEqual(@as(usize, 1), registered);
        // The losers' clients are closed and freed: one is left.
        const counts = fake.counts(io);
        try testing.expectEqual(@as(usize, 1), counts.opened - counts.freed);
        try testing.expectEqual(counts.freed, counts.closed);
        try testing.expectEqual(Registry.Stats.Connections{ .registered = 1, .connecting = 0, .active = 0, .failed = 0, .removing = 0 }, registry.stats(io).connections);
    }
    const counts = fake.counts(io);
    try testing.expectEqual(counts.opened, counts.freed);
    try testing.expectEqual(counts.opened, counts.closed);
}
