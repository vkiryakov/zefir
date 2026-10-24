//! Tests of odm.Registry on odm.testing.FakeDriver: registering and
//! connecting connections, ping and the stats, replacements with their
//! drains, removals, and the shutdown.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const core = @import("core");
const odm = @import("../root.zig");
const FakeDriver = odm.testing.FakeDriver;
const Registry = odm.Registry;
const Warning = @import("../registry/connection.zig").Warning;
const support = @import("support.zig");
const Outcome = support.Outcome;
const Canceled = support.Canceled;
const Journaled = support.Journaled;
const eventually = support.eventually;

fn registerTask(o: *Outcome, r: *Registry, io: Io, id: []const u8, uri: []const u8) void {
    o.set(r.registerConnection(io, id, .{ .uri = uri }));
}

fn connectTask(o: *Outcome, r: *Registry, io: Io, ctx: core.Context, id: []const u8) void {
    o.set(r.connect(io, ctx, id));
}

fn pingTask(o: *Outcome, r: *Registry, io: Io, id: []const u8) void {
    o.set(r.ping(io, .root, id));
}

fn replaceTask(o: *Outcome, r: *Registry, io: Io, id: []const u8, uri: []const u8) void {
    o.set(r.replaceConnection(io, .root, id, .{ .uri = uri }));
}

fn removeTask(o: *Outcome, r: *Registry, io: Io, id: []const u8) void {
    o.set(r.removeConnection(io, id));
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

/// A generation and a count of old ones that the stats of a connection
/// must show.
const Published = struct { r: *Registry, id: []const u8, generation: u64, draining: usize };

fn isPublished(e: Published, io: Io) bool {
    const s = e.r.connectionStats(io, e.id) catch return false;
    return s.generation == e.generation and s.draining == e.draining;
}

/// A count of freed clients that the fake must reach.
const Freed = struct { fake: *FakeDriver, n: usize };

fn isFreed(e: Freed, io: Io) bool {
    return e.fake.counts(io).freed >= e.n;
}

fn removing(r: *Registry, io: Io) bool {
    return r.stats(io).connections.removing == 1;
}

/// A count of clients that the fake must have opened.
const Opened = struct { fake: *FakeDriver, n: usize };

fn isOpened(e: Opened, io: Io) bool {
    return e.fake.counts(io).opened >= e.n;
}

test "replace" {
    const io = testing.io;
    var fake: FakeDriver = .init(testing.allocator);
    defer fake.deinit();
    var registry: Registry = .init(testing.allocator, io, fake.driver(), .{});
    defer registry.deinit(io);

    var gate: FakeDriver.Gate = .{};
    try fake.plan("fake://a", .{ .gate = &gate });
    try registry.registerConnection(io, "shared-1", .{ .uri = "fake://a", .password = "a" });
    try registry.connect(io, .root, "shared-1");
    {
        var group: Io.Group = .init;
        defer group.cancel(io);
        defer gate.open(io);
        var ping: Outcome = .{};
        try group.concurrent(io, pingTask, .{ &ping, &registry, io, "shared-1" });
        try gate.waitFor(io, 1);
        var replace: Outcome = .{};
        try group.concurrent(io, replaceTask, .{ &replace, &registry, io, "shared-1", "fake://b" });
        // The new generation is published; the old one drains, held by the ping.
        try eventually(io, Published{ .r = &registry, .id = "shared-1", .generation = 2, .draining = 1 }, isPublished);
        const s = try registry.connectionStats(io, "shared-1");
        try testing.expectEqual(odm.ConnectionState.active, s.state);
        try testing.expectEqual(@as(usize, 1), s.leases);
        try testing.expectEqual(@as(usize, 1), registry.stats(io).draining);
        // New calls go to the new generation, while the replace waits.
        try registry.ping(io, .root, "shared-1");
        const journal = fake.journal(io);
        try testing.expectEqualStrings("fake://b", journal[journal.len - 1].uri);
        try io.sleep(.fromMilliseconds(30), .awake);
        try testing.expect(!replace.done.load(.acquire));
        try testing.expectEqual(@as(usize, 0), fake.counts(io).closed);
        gate.open(io);
        try try ping.wait(io);
        try try replace.wait(io);
    }
    // The old client was closed once and freed.
    const counts = fake.counts(io);
    try testing.expectEqual(@as(usize, 2), counts.opened);
    try testing.expectEqual(@as(usize, 2), counts.connected);
    try testing.expectEqual(@as(usize, 1), counts.closed);
    try testing.expectEqual(@as(usize, 1), counts.close_calls);
    try testing.expectEqual(@as(usize, 1), counts.freed);
    const s = try registry.connectionStats(io, "shared-1");
    try testing.expectEqual(@as(u64, 2), s.generation);
    try testing.expectEqual(@as(usize, 0), s.draining);
    try testing.expectEqual(@as(usize, 0), registry.stats(io).draining);
    try testing.expectEqual(@as(usize, 0), registry.stats(io).forced);
    try testing.expectError(error.ConnectionNotFound, registry.replaceConnection(io, .root, "nope", .{ .uri = "fake://c" }));
}

test "the same settings again change nothing" {
    const io = testing.io;
    var fake: FakeDriver = .init(testing.allocator);
    defer fake.deinit();
    var registry: Registry = .init(testing.allocator, io, fake.driver(), .{});
    defer registry.deinit(io);

    try registry.registerConnection(io, "shared-1", .{ .uri = "fake://a", .password = "a" });
    try registry.connect(io, .root, "shared-1");
    try registry.replaceConnection(io, .root, "shared-1", .{ .uri = "fake://a", .password = "a" });
    try testing.expectEqual(@as(u64, 1), (try registry.connectionStats(io, "shared-1")).generation);
    try testing.expectEqual(@as(usize, 1), fake.counts(io).opened);
    // After a replacement, its settings are the ones that change nothing.
    try registry.replaceConnection(io, .root, "shared-1", .{ .uri = "fake://b", .password = "b" });
    try registry.replaceConnection(io, .root, "shared-1", .{ .uri = "fake://b", .password = "b" });
    try testing.expectEqual(@as(u64, 2), (try registry.connectionStats(io, "shared-1")).generation);
    try testing.expectEqual(@as(usize, 2), fake.counts(io).opened);
    // No password is not the empty one.
    try registry.replaceConnection(io, .root, "shared-1", .{ .uri = "fake://b", .password = "" });
    try testing.expectEqual(@as(u64, 3), (try registry.connectionStats(io, "shared-1")).generation);
}

test "a replacement judges its settings after the one in progress" {
    const io = testing.io;
    var fake: FakeDriver = .init(testing.allocator);
    defer fake.deinit();
    var registry: Registry = .init(testing.allocator, io, fake.driver(), .{});
    defer registry.deinit(io);

    try fake.plan("fake://b", .{ .connect_delay = .fromMilliseconds(500) });
    try registry.registerConnection(io, "x", .{ .uri = "fake://a" });
    try registry.connect(io, .root, "x");
    var group: Io.Group = .init;
    defer group.cancel(io);
    var replace: Outcome = .{};
    try group.concurrent(io, replaceTask, .{ &replace, &registry, io, "x", "fake://b" });
    // The replacement holds the turn once it has opened its client.
    try eventually(io, Opened{ .fake = &fake, .n = 2 }, isOpened);
    // The settings that the connection has now: the replacement in
    // progress publishes others, so this one comes after it and puts them
    // back.
    try registry.replaceConnection(io, .root, "x", .{ .uri = "fake://a" });
    try try replace.wait(io);
    try testing.expectEqual(@as(u64, 3), (try registry.connectionStats(io, "x")).generation);
    const counts = fake.counts(io);
    try testing.expectEqual(@as(usize, 3), counts.opened);
    try testing.expectEqual(@as(usize, 2), counts.freed);
    // The current settings are those of the later call.
    try registry.ping(io, .root, "x");
    const journal = fake.journal(io);
    try testing.expectEqualStrings("fake://a", journal[journal.len - 1].uri);
}

test "registered and failed take a fresh client even with the same settings" {
    const io = testing.io;
    var fake: FakeDriver = .init(testing.allocator);
    defer fake.deinit();
    var registry: Registry = .init(testing.allocator, io, fake.driver(), .{});
    defer registry.deinit(io);

    try registry.registerConnection(io, "fresh", .{ .uri = "fake://a" });
    try registry.replaceConnection(io, .root, "fresh", .{ .uri = "fake://a" });
    const fresh = try registry.connectionStats(io, "fresh");
    try testing.expectEqual(odm.ConnectionState.active, fresh.state);
    try testing.expectEqual(@as(u64, 2), fresh.generation);
    try testing.expectEqual(@as(usize, 2), fake.counts(io).opened);
    try testing.expectEqual(@as(usize, 1), fake.counts(io).freed);

    try fake.plan("fake://flaky", .{ .connects = &.{ error.Unavailable, null } });
    try registry.registerConnection(io, "retry", .{ .uri = "fake://flaky" });
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;
    try testing.expectError(error.Unavailable, registry.connect(io, .root, "retry"));
    try registry.replaceConnection(io, .root, "retry", .{ .uri = "fake://flaky" });
    const retry = try registry.connectionStats(io, "retry");
    try testing.expectEqual(odm.ConnectionState.active, retry.state);
    try testing.expectEqual(@as(u64, 2), retry.generation);
    const counts = fake.counts(io);
    try testing.expectEqual(@as(usize, 4), counts.opened);
    try testing.expectEqual(@as(usize, 2), counts.closed);
    try testing.expectEqual(@as(usize, 2), counts.freed);
}

test "failed replacement rollback" {
    const io = testing.io;
    var fake: FakeDriver = .init(testing.allocator);
    defer fake.deinit();
    var registry: Registry = .init(testing.allocator, io, fake.driver(), .{});
    defer registry.deinit(io);

    try registry.registerConnection(io, "shared-1", .{ .uri = "fake://a" });
    try registry.connect(io, .root, "shared-1");
    try fake.plan("fake://b", .{ .connects = &.{error.AuthenticationFailed} });
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;
    var d: odm.Diagnostics = .{};
    try testing.expectError(error.AuthenticationFailed, registry.replaceConnection(io, .root, "shared-1", .{ .uri = "fake://b", .diagnostics = &d }));
    try testing.expectEqualStrings("the plan of the fake fails this connect with AuthenticationFailed", d.message());
    const s = try registry.connectionStats(io, "shared-1");
    try testing.expectEqual(odm.ConnectionState.active, s.state);
    try testing.expectEqual(@as(u64, 1), s.generation);
    try testing.expectEqual(@as(usize, 0), s.draining);
    try testing.expectEqual(odm.DriverError.AuthenticationFailed, s.last_failure.?.err);
    try testing.expectEqualStrings("the plan of the fake fails this connect with AuthenticationFailed", s.last_failure.?.message());
    // The new client is closed and freed; the old generation serves on.
    var counts = fake.counts(io);
    try testing.expectEqual(@as(usize, 2), counts.opened);
    try testing.expectEqual(@as(usize, 1), counts.closed);
    try testing.expectEqual(@as(usize, 1), counts.freed);
    try registry.ping(io, .root, "shared-1");
    const journal = fake.journal(io);
    try testing.expectEqualStrings("fake://a", journal[journal.len - 1].uri);

    // An open that the driver refuses rolls back the same way.
    try fake.plan("fake://refused", .{ .open = error.Unsupported });
    try testing.expectError(error.Unsupported, registry.replaceConnection(io, .root, "shared-1", .{ .uri = "fake://refused", .diagnostics = &d }));
    try testing.expectEqualStrings("the plan of the fake refuses to open a client: Unsupported", d.message());
    const refused = try registry.connectionStats(io, "shared-1");
    try testing.expectEqual(odm.ConnectionState.active, refused.state);
    try testing.expectEqual(@as(u64, 1), refused.generation);
    try testing.expectEqual(odm.DriverError.Unsupported, refused.last_failure.?.err);
    counts = fake.counts(io);
    try testing.expectEqual(@as(usize, 2), counts.opened);
}

test "a drain past drain_timeout closes by force" {
    const io = testing.io;
    var fake: FakeDriver = .init(testing.allocator);
    defer fake.deinit();
    var registry: Registry = .init(testing.allocator, io, fake.driver(), .{ .drain_timeout = .fromMilliseconds(100) });
    defer registry.deinit(io);

    var gate: FakeDriver.Gate = .{};
    try fake.plan("fake://a", .{ .gate = &gate });
    try registry.registerConnection(io, "shared-1", .{ .uri = "fake://a" });
    try registry.connect(io, .root, "shared-1");
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;
    {
        var group: Io.Group = .init;
        defer group.cancel(io);
        defer gate.open(io);
        var ping: Outcome = .{};
        try group.concurrent(io, pingTask, .{ &ping, &registry, io, "shared-1" });
        try gate.waitFor(io, 1);
        const start = Io.Clock.awake.now(io);
        try registry.replaceConnection(io, .root, "shared-1", .{ .uri = "fake://b" });
        try testing.expect(start.durationTo(Io.Clock.awake.now(io)).nanoseconds >= 100 * std.time.ns_per_ms);
        // The close cut the ping.
        try testing.expectError(error.Closed, try ping.wait(io));
    }
    const s = registry.stats(io);
    try testing.expectEqual(@as(usize, 1), s.forced);
    try testing.expectEqual(@as(usize, 0), s.leases);
    try testing.expectEqual(@as(usize, 0), s.draining);
    // The last lease freed the old generation.
    try eventually(io, Freed{ .fake = &fake, .n = 1 }, isFreed);
    const counts = fake.counts(io);
    try testing.expectEqual(@as(usize, 1), counts.closed);
    try testing.expectEqual(@as(usize, 1), counts.freed);
    try testing.expectFmt("connection shared-1: generation 1 closed by force with 1 leases left after 100ms", "{f}", .{Warning{ .forced = .{ .id = "shared-1", .generation = 1, .leases = 1, .after = .fromMilliseconds(100) } }});
}

test "remove connection" {
    const io = testing.io;
    var fake: FakeDriver = .init(testing.allocator);
    defer fake.deinit();
    var registry: Registry = .init(testing.allocator, io, fake.driver(), .{});
    defer registry.deinit(io);

    try registry.registerConnection(io, "gone", .{ .uri = "fake://a" });
    try registry.connect(io, .root, "gone");
    try registry.removeConnection(io, "gone");
    try testing.expectError(error.ConnectionNotFound, registry.connectionStats(io, "gone"));
    try testing.expectError(error.ConnectionNotFound, registry.ping(io, .root, "gone"));
    try testing.expectError(error.ConnectionNotFound, registry.removeConnection(io, "gone"));
    try testing.expectError(error.ConnectionNotFound, registry.removeConnection(io, "nope"));
    try testing.expectEqual(@as(usize, 1), fake.counts(io).closed);
    try testing.expectEqual(@as(usize, 1), fake.counts(io).freed);
    // The id is free again.
    try registry.registerConnection(io, "gone", .{ .uri = "fake://a" });
    try testing.expectEqual(@as(u64, 1), (try registry.connectionStats(io, "gone")).generation);

    // A registered one goes as well.
    try registry.removeConnection(io, "gone");
    try testing.expectEqual(@as(usize, 2), fake.counts(io).freed);

    // With a ping in flight, the removal waits for its drain.
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
        var remove: Outcome = .{};
        try group.concurrent(io, removeTask, .{ &remove, &registry, io, "held" });
        try eventually(io, &registry, removing);
        // The id finds nothing at once; the generation drains.
        try testing.expectError(error.ConnectionNotFound, registry.connectionStats(io, "held"));
        try testing.expectEqual(@as(usize, 1), registry.stats(io).draining);
        try io.sleep(.fromMilliseconds(30), .awake);
        try testing.expect(!remove.done.load(.acquire));
        gate.open(io);
        try try ping.wait(io);
        try try remove.wait(io);
    }
    const s = registry.stats(io);
    try testing.expectEqual(@as(usize, 0), s.connections.removing);
    try testing.expectEqual(@as(usize, 0), s.draining);
    try testing.expectEqual(@as(usize, 0), s.forced);
    try testing.expectEqual(@as(usize, 3), fake.counts(io).freed);
}

test "replace and remove of one id run one after the other" {
    const io = testing.io;
    var fake: FakeDriver = .init(testing.allocator);
    defer fake.deinit();
    var registry: Registry = .init(testing.allocator, io, fake.driver(), .{});
    defer registry.deinit(io);

    var gate: FakeDriver.Gate = .{};
    try fake.plan("fake://a", .{ .gate = &gate });
    try registry.registerConnection(io, "x", .{ .uri = "fake://a" });
    try registry.connect(io, .root, "x");
    {
        var group: Io.Group = .init;
        defer group.cancel(io);
        defer gate.open(io);
        var ping: Outcome = .{};
        try group.concurrent(io, pingTask, .{ &ping, &registry, io, "x" });
        try gate.waitFor(io, 1);
        var replace: Outcome = .{};
        try group.concurrent(io, replaceTask, .{ &replace, &registry, io, "x", "fake://b" });
        try eventually(io, Published{ .r = &registry, .id = "x", .generation = 2, .draining = 1 }, isPublished);
        // The removal waits while the replacement drains the old generation.
        var remove: Outcome = .{};
        try group.concurrent(io, removeTask, .{ &remove, &registry, io, "x" });
        try io.sleep(.fromMilliseconds(30), .awake);
        try testing.expect(!remove.done.load(.acquire));
        try testing.expectEqual(@as(u64, 2), (try registry.connectionStats(io, "x")).generation);
        gate.open(io);
        try try ping.wait(io);
        try try replace.wait(io);
        try try remove.wait(io);
    }
    try testing.expectError(error.ConnectionNotFound, registry.connectionStats(io, "x"));
    const counts = fake.counts(io);
    try testing.expectEqual(@as(usize, 2), counts.opened);
    try testing.expectEqual(@as(usize, 2), counts.closed);
    try testing.expectEqual(@as(usize, 2), counts.freed);
}

test "the warnings of the registry" {
    try testing.expectFmt(
        "connection shared-1: generation 3 closed by force with 2 leases left after 30s",
        "{f}",
        .{Warning{ .forced = .{ .id = "shared-1", .generation = 3, .leases = 2, .after = .fromSeconds(30) } }},
    );
    try testing.expectFmt(
        "connection big-1: connect failed: AuthenticationFailed: Authentication failed.",
        "{f}",
        .{Warning{ .connect_failed = .{ .id = "big-1", .err = error.AuthenticationFailed, .message = "Authentication failed." } }},
    );
    try testing.expectFmt(
        "shutdown: 2 leases left at the deadline; their generations were closed by force",
        "{f}",
        .{Warning{ .shutdown_forced = .{ .leases = 2 } }},
    );
}

fn shutdownTask(o: *Outcome, r: *Registry, io: Io, budget: Io.Duration) void {
    const deadline = Io.Clock.Timestamp.fromNow(io, .{ .raw = budget, .clock = .awake });
    o.set(r.shutdown(io, deadline));
}

test "shutdown" {
    const io = testing.io;
    var fake: FakeDriver = .init(testing.allocator);
    defer fake.deinit();
    {
        var registry: Registry = .init(testing.allocator, io, fake.driver(), .{});
        defer registry.deinit(io);
        try registry.registerConnection(io, "active", .{ .uri = "fake://a" });
        try registry.connect(io, .root, "active");
        try registry.registerConnection(io, "registered", .{ .uri = "fake://b" });

        try registry.shutdown(io, .fromNow(io, .{ .raw = .fromSeconds(1), .clock = .awake }));
        // Both clients are closed and freed, none by force.
        var counts = fake.counts(io);
        try testing.expectEqual(@as(usize, 2), counts.closed);
        try testing.expectEqual(@as(usize, 2), counts.freed);
        const s = registry.stats(io);
        try testing.expectEqual(@as(usize, 0), s.forced);
        try testing.expectEqual(@as(usize, 0), s.leases);
        try testing.expectEqual(@as(usize, 0), s.draining);
        // No connection is in service any more.
        try testing.expectEqual(Registry.Stats.Connections{ .registered = 0, .connecting = 0, .active = 0, .failed = 0, .removing = 0 }, s.connections);

        var d: odm.Diagnostics = .{};
        try testing.expectError(error.ShuttingDown, registry.registerConnection(io, "new", .{ .uri = "fake://c", .diagnostics = &d }));
        try testing.expectEqualStrings("odm: the registry is shutting down", d.message());
        try testing.expectError(error.ShuttingDown, registry.connect(io, .root, "registered"));
        try testing.expectError(error.ShuttingDown, registry.replaceConnection(io, .root, "active", .{ .uri = "fake://c" }));
        try testing.expectError(error.ShuttingDown, registry.removeConnection(io, "active"));
        try testing.expectError(error.ShuttingDown, registry.ping(io, .root, "active"));
        try testing.expectError(error.ShuttingDown, registry.connectionStats(io, "active"));
        // A second shutdown returns the result of the first.
        try registry.shutdown(io, .now(io, .awake));
        // The registration it refused opened no client.
        counts = fake.counts(io);
        try testing.expectEqual(@as(usize, 2), counts.opened);
    }
    const counts = fake.counts(io);
    try testing.expectEqual(counts.opened, counts.freed);
    try testing.expectEqual(counts.opened, counts.close_calls);
}

test "shutdown wakes the calls that wait, and closes a connect in its delay at once" {
    const io = testing.io;
    var fake: FakeDriver = .init(testing.allocator);
    defer fake.deinit();
    {
        var registry: Registry = .init(testing.allocator, io, fake.driver(), .{});
        defer registry.deinit(io);
        try fake.plan("fake://slow", .{ .connect_delay = .fromSeconds(10) });
        try registry.registerConnection(io, "slow", .{ .uri = "fake://slow" });
        var group: Io.Group = .init;
        defer group.cancel(io);
        var connecting: Outcome = .{};
        try group.concurrent(io, connectTask, .{ &connecting, &registry, io, core.Context.root, "slow" });
        try eventually(io, Expected{ .r = &registry, .id = "slow", .state = .connecting }, inState);
        // Both wait for their turn behind the connect.
        var waiting: Outcome = .{};
        try group.concurrent(io, connectTask, .{ &waiting, &registry, io, core.Context.root, "slow" });
        var replacing: Outcome = .{};
        try group.concurrent(io, replaceTask, .{ &replacing, &registry, io, "slow", "fake://other" });
        try io.sleep(.fromMilliseconds(20), .awake);

        const start = Io.Clock.awake.now(io);
        try registry.shutdown(io, .fromNow(io, .{ .raw = .fromSeconds(5), .clock = .awake }));
        // The generation that never connected closed at once, and not by force.
        try testing.expect(start.durationTo(Io.Clock.awake.now(io)).nanoseconds < 2 * std.time.ns_per_s);
        try testing.expectError(error.ShuttingDown, try connecting.wait(io));
        try testing.expectError(error.ShuttingDown, try waiting.wait(io));
        try testing.expectError(error.ShuttingDown, try replacing.wait(io));
        try testing.expectEqual(@as(usize, 0), registry.stats(io).forced);
        try eventually(io, Freed{ .fake = &fake, .n = 1 }, isFreed);
        const counts = fake.counts(io);
        try testing.expectEqual(@as(usize, 1), counts.opened);
        try testing.expectEqual(@as(usize, 0), counts.connected);
        try testing.expectEqual(@as(usize, 1), counts.closed);
    }
    const counts = fake.counts(io);
    try testing.expectEqual(counts.opened, counts.freed);
}

test "a lease past the deadline of shutdown is closed by force" {
    const io = testing.io;
    var fake: FakeDriver = .init(testing.allocator);
    defer fake.deinit();
    {
        var registry: Registry = .init(testing.allocator, io, fake.driver(), .{});
        defer registry.deinit(io);
        var gate: FakeDriver.Gate = .{};
        defer gate.open(io);
        try fake.plan("fake://held", .{ .gate = &gate });
        try registry.registerConnection(io, "held", .{ .uri = "fake://held" });
        try registry.connect(io, .root, "held");
        const level = testing.log_level;
        testing.log_level = .err;
        defer testing.log_level = level;
        var group: Io.Group = .init;
        defer group.cancel(io);
        var ping: Outcome = .{};
        try group.concurrent(io, pingTask, .{ &ping, &registry, io, "held" });
        try gate.waitFor(io, 1);

        const start = Io.Clock.awake.now(io);
        var first: Outcome = .{};
        try group.concurrent(io, shutdownTask, .{ &first, &registry, io, Io.Duration.fromMilliseconds(100) });
        // A second shutdown, with a deadline far away, waits for the first
        // and returns its result.
        try io.sleep(.fromMilliseconds(20), .awake);
        var second: Outcome = .{};
        try group.concurrent(io, shutdownTask, .{ &second, &registry, io, Io.Duration.fromSeconds(30) });
        try testing.expectError(error.ShutdownTimeout, try first.wait(io));
        try testing.expect(start.durationTo(Io.Clock.awake.now(io)).nanoseconds >= 100 * std.time.ns_per_ms);
        try testing.expectError(error.ShutdownTimeout, try second.wait(io));
        // The holder got Closed, and its release freed the generation.
        try testing.expectError(error.Closed, try ping.wait(io));
        try eventually(io, Freed{ .fake = &fake, .n = 1 }, isFreed);
        const s = registry.stats(io);
        try testing.expectEqual(@as(usize, 1), s.forced);
        try testing.expectEqual(@as(usize, 0), s.leases);
        try testing.expectEqual(@as(usize, 0), s.draining);
        try testing.expectError(error.ShutdownTimeout, registry.shutdown(io, .now(io, .awake)));
    }
    const counts = fake.counts(io);
    try testing.expectEqual(counts.opened, counts.freed);
}

test "a shutdown counts the leases left at its deadline of a generation that a drain closed by force meanwhile" {
    const io = testing.io;
    var fake: FakeDriver = .init(testing.allocator);
    defer fake.deinit();
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;
    {
        var registry: Registry = .init(testing.allocator, io, fake.driver(), .{ .drain_timeout = .fromSeconds(1) });
        defer registry.deinit(io);
        var gate: FakeDriver.Gate = .{};
        try fake.plan("fake://a", .{ .gate = &gate });
        try registry.registerConnection(io, "shared-1", .{ .uri = "fake://a" });
        try registry.connect(io, .root, "shared-1");
        var group: Io.Group = .init;
        defer group.cancel(io);
        defer gate.open(io);
        var ping: Outcome = .{};
        try group.concurrent(io, pingTask, .{ &ping, &registry, io, "shared-1" });
        try gate.waitFor(io, 1);
        var replace: Outcome = .{};
        try group.concurrent(io, replaceTask, .{ &replace, &registry, io, "shared-1", "fake://b" });
        try eventually(io, Published{ .r = &registry, .id = "shared-1", .generation = 2, .draining = 1 }, isPublished);
        // The shutdown takes the old generation while the replacement
        // drains it, and the drain runs out first: the replacement closes
        // it by force, with the ping's lease left.
        var stop: Outcome = .{};
        try group.concurrent(io, shutdownTask, .{ &stop, &registry, io, Io.Duration.fromSeconds(10) });
        try testing.expectError(error.Closed, try ping.wait(io));
        try try replace.wait(io);
        // The ping gave its lease back long before the deadline of the
        // shutdown: none was left then.
        try try stop.wait(io);
        const s = registry.stats(io);
        try testing.expectEqual(@as(usize, 1), s.forced);
        try testing.expectEqual(@as(usize, 0), s.leases);
    }
    const counts = fake.counts(io);
    try testing.expectEqual(@as(usize, 2), counts.opened);
    try testing.expectEqual(counts.opened, counts.freed);
}

fn replaceCanceled(c: *Canceled, r: *Registry, io: Io, id: []const u8, uri: []const u8) void {
    c.set(io, r.replaceConnection(io, .root, id, .{ .uri = uri }));
}

fn removeCanceled(c: *Canceled, r: *Registry, io: Io, id: []const u8) void {
    c.set(io, r.removeConnection(io, id));
}

fn shutdownCanceled(c: *Canceled, r: *Registry, io: Io, budget: Io.Duration) void {
    c.set(io, r.shutdown(io, .fromNow(io, .{ .raw = budget, .clock = .awake })));
}

fn stopping(r: *Registry, io: Io) bool {
    _ = r.connectionStats(io, "held") catch |err| return err == error.ShuttingDown;
    return false;
}

test "a replacement canceled in its drain drains to the end, and its task gets the cancelation after it" {
    const io = testing.io;
    var fake: FakeDriver = .init(testing.allocator);
    defer fake.deinit();
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;
    var registry: Registry = .init(testing.allocator, io, fake.driver(), .{ .drain_timeout = .fromMilliseconds(500) });
    defer registry.deinit(io);
    var gate: FakeDriver.Gate = .{};
    try fake.plan("fake://a", .{ .gate = &gate });
    try registry.registerConnection(io, "shared-1", .{ .uri = "fake://a" });
    try registry.connect(io, .root, "shared-1");
    {
        var group: Io.Group = .init;
        defer group.cancel(io);
        defer gate.open(io);
        var ping: Outcome = .{};
        try group.concurrent(io, pingTask, .{ &ping, &registry, io, "shared-1" });
        try gate.waitFor(io, 1);
        var replace: Canceled = .{};
        var task = try io.concurrent(replaceCanceled, .{ &replace, &registry, io, "shared-1", "fake://b" });
        defer task.cancel(io);
        try eventually(io, Published{ .r = &registry, .id = "shared-1", .generation = 2, .draining = 1 }, isPublished);
        // The cancelation waits until the drain runs out and closes the old
        // generation by force.
        task.cancel(io);
        try replace.result;
        try testing.expect(replace.after);
        try testing.expectError(error.Closed, try ping.wait(io));
    }
    const s = registry.stats(io);
    try testing.expectEqual(@as(usize, 1), s.forced);
    try testing.expectEqual(@as(usize, 0), s.leases);
    try testing.expectEqual(@as(u64, 2), (try registry.connectionStats(io, "shared-1")).generation);
    try eventually(io, Freed{ .fake = &fake, .n = 1 }, isFreed);
    const counts = fake.counts(io);
    try testing.expectEqual(@as(usize, 1), counts.closed);
    try testing.expectEqual(@as(usize, 1), counts.close_calls);
}

test "a replacement canceled in the connect of its client rolls back, and its task stays canceled" {
    const io = testing.io;
    var fake: FakeDriver = .init(testing.allocator);
    defer fake.deinit();
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;
    var registry: Registry = .init(testing.allocator, io, fake.driver(), .{});
    defer registry.deinit(io);
    // Only the cancelation ends this connect.
    try fake.plan("fake://b", .{ .connect_delay = .fromSeconds(60) });
    try registry.registerConnection(io, "shared-1", .{ .uri = "fake://a" });
    try registry.connect(io, .root, "shared-1");
    const mark = fake.journal(io).len;
    {
        var replace: Canceled = .{};
        var task = try io.concurrent(replaceCanceled, .{ &replace, &registry, io, "shared-1", "fake://b" });
        defer task.cancel(io);
        // The connect of the new client is out.
        try eventually(io, Journaled{ .fake = &fake, .n = mark + 1 }, support.isJournaled);
        task.cancel(io);
        try testing.expectError(error.Cancelled, replace.result);
        try testing.expect(replace.after);
    }
    // The new generation went; the current one serves on.
    const s = try registry.connectionStats(io, "shared-1");
    try testing.expectEqual(odm.ConnectionState.active, s.state);
    try testing.expectEqual(@as(u64, 1), s.generation);
    try testing.expectEqual(@as(usize, 0), s.draining);
    try testing.expectEqual(odm.DriverError.Cancelled, s.last_failure.?.err);
    const counts = fake.counts(io);
    try testing.expectEqual(@as(usize, 2), counts.opened);
    try testing.expectEqual(@as(usize, 1), counts.closed);
    try testing.expectEqual(@as(usize, 1), counts.freed);
    try registry.ping(io, .root, "shared-1");
    const journal = fake.journal(io);
    try testing.expectEqualStrings("fake://a", journal[journal.len - 1].uri);
}

/// Opens `gate` a little later, in a task of its own.
fn openLater(gate: *FakeDriver.Gate, io: Io) void {
    io.sleep(.fromMilliseconds(100), .awake) catch {};
    gate.open(io);
}

test "a removal canceled in its drain removes to the end, and its task gets the cancelation after it" {
    const io = testing.io;
    var fake: FakeDriver = .init(testing.allocator);
    defer fake.deinit();
    // The removal frees its record after the drain, in its canceled task.
    // On macOS std drops a cancelation that comes during the stack trace
    // that std.testing.allocator takes at a free, so the registry's memory
    // comes from an allocator that takes none.
    var gpa: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{ .stack_trace_frames = 0 });
    {
        var registry: Registry = .init(gpa.allocator(), io, fake.driver(), .{});
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
            var remove: Canceled = .{};
            var task = try io.concurrent(removeCanceled, .{ &remove, &registry, io, "held" });
            defer task.cancel(io);
            try eventually(io, &registry, removing);
            // The ping returns once the gate opens, and the drain ends then.
            try group.concurrent(io, openLater, .{ &gate, io });
            // The cancelation waits for the drain.
            task.cancel(io);
            try remove.result;
            try testing.expect(remove.after);
            try try ping.wait(io);
        }
        try testing.expectError(error.ConnectionNotFound, registry.connectionStats(io, "held"));
        const s = registry.stats(io);
        try testing.expectEqual(@as(usize, 0), s.connections.removing);
        try testing.expectEqual(@as(usize, 0), s.forced);
        try testing.expectEqual(@as(usize, 0), s.leases);
        const counts = fake.counts(io);
        try testing.expectEqual(@as(usize, 1), counts.closed);
        try testing.expectEqual(@as(usize, 1), counts.freed);
        // The id is free again: the record went.
        try registry.registerConnection(io, "held", .{ .uri = "fake://held" });
    }
    try testing.expectEqual(@as(usize, 0), gpa.deinit());
}

test "a shutdown in a canceled task goes to its end, and a second one returns its result" {
    const io = testing.io;
    var fake: FakeDriver = .init(testing.allocator);
    defer fake.deinit();
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;
    {
        var registry: Registry = .init(testing.allocator, io, fake.driver(), .{});
        defer registry.deinit(io);
        var gate: FakeDriver.Gate = .{};
        try fake.plan("fake://held", .{ .gate = &gate });
        try registry.registerConnection(io, "held", .{ .uri = "fake://held" });
        try registry.connect(io, .root, "held");
        try registry.registerConnection(io, "idle", .{ .uri = "fake://idle" });
        var group: Io.Group = .init;
        defer group.cancel(io);
        defer gate.open(io);
        var ping: Outcome = .{};
        try group.concurrent(io, pingTask, .{ &ping, &registry, io, "held" });
        try gate.waitFor(io, 1);
        var stop: Canceled = .{};
        var task = try io.concurrent(shutdownCanceled, .{ &stop, &registry, io, Io.Duration.fromMilliseconds(500) });
        defer task.cancel(io);
        try eventually(io, &registry, stopping);
        // The cancelation waits until the deadline closes the held
        // generation by force.
        task.cancel(io);
        try testing.expectError(error.ShutdownTimeout, stop.result);
        try testing.expect(stop.after);
        try testing.expectError(error.Closed, try ping.wait(io));
        try testing.expectError(error.ShutdownTimeout, registry.shutdown(io, .now(io, .awake)));
        // Every client is closed.
        const counts = fake.counts(io);
        try testing.expectEqual(@as(usize, 2), counts.opened);
        try testing.expectEqual(@as(usize, 2), counts.closed);
        try testing.expectEqual(@as(usize, 1), registry.stats(io).forced);
    }
    const counts = fake.counts(io);
    try testing.expectEqual(counts.opened, counts.freed);
}

test "deinit without shutdown shuts down by now" {
    const io = testing.io;
    var fake: FakeDriver = .init(testing.allocator);
    defer fake.deinit();
    {
        var registry: Registry = .init(testing.allocator, io, fake.driver(), .{});
        defer registry.deinit(io);
        try registry.registerConnection(io, "a", .{ .uri = "fake://a" });
        try registry.connect(io, .root, "a");
        try registry.registerConnection(io, "b", .{ .uri = "fake://b" });
        try registry.replaceConnection(io, .root, "a", .{ .uri = "fake://c" });
        try testing.expectEqual(@as(usize, 1), fake.counts(io).freed);
    }
    const counts = fake.counts(io);
    try testing.expectEqual(@as(usize, 3), counts.opened);
    try testing.expectEqual(@as(usize, 3), counts.closed);
    try testing.expectEqual(@as(usize, 3), counts.close_calls);
    try testing.expectEqual(@as(usize, 3), counts.freed);
}
