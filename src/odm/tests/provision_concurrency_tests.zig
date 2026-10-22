//! Tests of provisioning under concurrency on odm.testing.FakeDriver: two
//! tenants that make one new connection at once, a shutdown in the middle
//! of provisionings and a replacement, and many tasks that provision one
//! tenant while others take its sessions. Every wait is a loop on the
//! .awake clock, so that a call that never returns fails the test.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const core = @import("core");
const odm = @import("../root.zig");
const support = @import("support.zig");
const FakeDriver = odm.testing.FakeDriver;
const Registry = odm.Registry;
const Outcome = support.Outcome;
const eventually = support.eventually;

fn provisionTask(o: *Outcome, r: *Registry, io: Io, request: odm.Provision) void {
    o.set(r.provisionTenant(io, .root, request));
}

fn replaceTask(o: *Outcome, r: *Registry, io: Io, id: []const u8, uri: []const u8) void {
    o.set(r.replaceConnection(io, .root, id, .{ .uri = uri }));
}

/// A provisioning of `tenant_id` on the new connection `id`.
fn fresh(tenant_id: []const u8, id: []const u8, uri: []const u8, password: []const u8) odm.Provision {
    return .{
        .tenant = tenant_id,
        .connection = .{ .new = .{ .id = id, .uri = uri, .password = password } },
        .database = tenant_id,
        .version = 1,
    };
}

/// Two provisionings at once, each in a task of its own.
fn race(registry: *Registry, io: Io, a: odm.Provision, b: odm.Provision) ![2]support.CallError!void {
    var first: Outcome = .{};
    var second: Outcome = .{};
    var group: Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, provisionTask, .{ &first, registry, io, a });
    try group.concurrent(io, provisionTask, .{ &second, registry, io, b });
    return .{ try first.wait(io), try second.wait(io) };
}

test "two tenants provision one new connection at once" {
    const io = testing.io;
    var fake: FakeDriver = .init(testing.allocator);
    defer fake.deinit();
    {
        var registry: Registry = .init(testing.allocator, io, fake.driver(), .{});
        defer registry.deinit(io);
        for (0..20) |round| {
            var names: [6][16]u8 = undefined;
            const same = try std.fmt.bufPrint(&names[0], "same-{d}", .{round});
            const a = try std.fmt.bufPrint(&names[1], "a-{d}", .{round});
            const b = try std.fmt.bufPrint(&names[2], "b-{d}", .{round});

            // The same settings: both are bound to one connection, and of
            // the clients that the race opened one is left.
            var before = fake.counts(io);
            const both = try race(&registry, io, fresh(a, same, "fake://same", "pw"), fresh(b, same, "fake://same", "pw"));
            try both[0];
            try both[1];
            var after = fake.counts(io);
            try testing.expectEqual(@as(usize, 1), (after.opened - before.opened) - (after.freed - before.freed));
            const s = try registry.connectionStats(io, same);
            try testing.expectEqual(odm.ConnectionState.active, s.state);
            try testing.expectEqual(@as(usize, 2), s.tenants);

            // Other settings: one is bound, the other gets ProvisioningConflict.
            const other = try std.fmt.bufPrint(&names[3], "other-{d}", .{round});
            const c = try std.fmt.bufPrint(&names[4], "c-{d}", .{round});
            const e = try std.fmt.bufPrint(&names[5], "e-{d}", .{round});
            before = fake.counts(io);
            const one = try race(&registry, io, fresh(c, other, "fake://other", "1"), fresh(e, other, "fake://other", "2"));
            var bound: usize = 0;
            for (one) |result| {
                if (result) |_| {
                    bound += 1;
                } else |err| {
                    try testing.expectEqual(error.ProvisioningConflict, err);
                }
            }
            try testing.expectEqual(@as(usize, 1), bound);
            after = fake.counts(io);
            try testing.expectEqual(@as(usize, 1), (after.opened - before.opened) - (after.freed - before.freed));
            try testing.expectEqual(@as(usize, 1), (try registry.connectionStats(io, other)).tenants);
        }
        const s = registry.stats(io);
        try testing.expectEqual(@as(usize, 40), s.connections.active);
        try testing.expectEqual(@as(usize, 60), s.tenants);
        try testing.expectEqual(@as(usize, 0), s.leases);
        // Every client left is in a registered connection.
        const counts = fake.counts(io);
        try testing.expectEqual(@as(usize, 40), counts.opened - counts.freed);
        try testing.expectEqual(counts.freed, counts.closed);
    }
    const counts = fake.counts(io);
    try testing.expectEqual(counts.opened, counts.freed);
    try testing.expectEqual(counts.opened, counts.closed);
}

fn connecting(r: *Registry, io: Io) bool {
    const s = r.connectionStats(io, "big-1") catch return false;
    return s.state == .connecting;
}

/// The lease of the provisioning's connect and the replacement's own lease
/// of its new generation: both calls are in their connects.
fn twoLeases(r: *Registry, io: Io) bool {
    return r.stats(io).leases == 2;
}

test "shutdown in the middle of provisioning and replacement" {
    const io = testing.io;
    var fake: FakeDriver = .init(testing.allocator);
    defer fake.deinit();
    {
        var registry: Registry = .init(testing.allocator, io, fake.driver(), .{});
        defer registry.deinit(io);
        try fake.plan("fake://slow", .{ .connect_delay = .fromSeconds(10) });
        try fake.plan("fake://b", .{ .connect_delay = .fromSeconds(10) });
        try registry.registerConnection(io, "shared-1", .{ .uri = "fake://a" });
        try registry.connect(io, .root, "shared-1");

        var group: Io.Group = .init;
        defer group.cancel(io);
        // A provisioning in the connect of the connection it made.
        var making: Outcome = .{};
        try group.concurrent(io, provisionTask, .{ &making, &registry, io, fresh("big", "big-1", "fake://slow", "pw") });
        try eventually(io, &registry, connecting);
        // A second provisioning of that tenant, waiting for its turn.
        var waiting: Outcome = .{};
        const second: odm.Provision = .{ .tenant = "big", .connection = .{ .existing = "shared-1" }, .database = "big", .version = 2 };
        try group.concurrent(io, provisionTask, .{ &waiting, &registry, io, second });
        // A replacement in the connect of its new client.
        var replacing: Outcome = .{};
        try group.concurrent(io, replaceTask, .{ &replacing, &registry, io, "shared-1", "fake://b" });
        try eventually(io, &registry, twoLeases);
        try io.sleep(.fromMilliseconds(20), .awake);
        try testing.expect(!waiting.done.load(.acquire));

        const start = Io.Clock.awake.now(io);
        try registry.shutdown(io, .fromNow(io, .{ .raw = .fromSeconds(1), .clock = .awake }));
        // Nothing waited for a connect to end, and nothing was closed by force.
        try testing.expect(start.durationTo(Io.Clock.awake.now(io)).nanoseconds < std.time.ns_per_s);
        try testing.expectError(error.ShuttingDown, try making.wait(io));
        try testing.expectError(error.ShuttingDown, try waiting.wait(io));
        try testing.expectError(error.ShuttingDown, try replacing.wait(io));
        const s = registry.stats(io);
        try testing.expectEqual(@as(usize, 0), s.forced);
        try testing.expectEqual(@as(usize, 0), s.leases);
        try testing.expectEqual(@as(usize, 0), s.tenants);
    }
    // The half-made connection and the replacement's client were freed once.
    const counts = fake.counts(io);
    try testing.expectEqual(@as(usize, 3), counts.opened);
    try testing.expectEqual(@as(usize, 1), counts.connected);
    try testing.expectEqual(counts.opened, counts.closed);
    try testing.expectEqual(counts.opened, counts.freed);
}

/// Versions 1 to 20 of one tenant, in a shuffled order, from eight tasks:
/// an even version on "shared-1", an odd one on "shared-2".
const Storm = struct {
    registry: *Registry,
    order: [20]u64,
    names: [21][16]u8 = undefined,
    lengths: [21]usize = undefined,
    applied: std.atomic.Value(usize) = .init(0),
    stale: std.atomic.Value(usize) = .init(0),
    unexpected: std.atomic.Value(usize) = .init(0),

    const tasks = 8;

    fn database(storm: *const Storm, version: u64) []const u8 {
        return storm.names[version][0..storm.lengths[version]];
    }

    /// The versions at `k`, `k + 8`, `k + 16` of the order.
    fn provision(storm: *Storm, io: Io, k: usize) void {
        var i = k;
        while (i < storm.order.len) : (i += tasks) {
            const version = storm.order[i];
            const id = if (version % 2 == 0) "shared-1" else "shared-2";
            const request: odm.Provision = .{ .tenant = "acme", .connection = .{ .existing = id }, .database = storm.database(version), .version = version };
            if (storm.registry.provisionTenant(io, .root, request)) |_| {
                _ = storm.applied.fetchAdd(1, .monotonic);
            } else |err| switch (err) {
                error.StaleVersion => _ = storm.stale.fetchAdd(1, .monotonic),
                else => if (storm.unexpected.fetchAdd(1, .monotonic) == 0) std.debug.print("unexpected error of provisionTenant: {t}\n", .{err}),
            }
        }
    }
};

/// Takes sessions of the tenant until told to stop: once one came, every
/// later one must come too, and its version never goes down.
const Reader = struct {
    registry: *Registry,
    stop: std.atomic.Value(bool) = .init(false),
    /// The version of the latest session, 0 before the first one.
    seen: std.atomic.Value(u64) = .init(0),
    sessions: usize = 0,
    problems: usize = 0,

    fn run(reader: *Reader, io: Io) void {
        while (!reader.stop.load(.acquire)) {
            if (reader.registry.tenant(io, "acme")) |got| {
                var session = got;
                defer session.deinit(io);
                const version = std.fmt.parseInt(u64, session.database()["acme_v".len..], 10) catch 0;
                if (version < reader.seen.load(.monotonic) or version == 0) reader.problems += 1;
                reader.seen.store(version, .release);
                reader.sessions += 1;
            } else |err| {
                // Only before the first provisioning: no binding yet.
                if (err != error.TenantNotFound or reader.seen.load(.monotonic) != 0) reader.problems += 1;
            }
            io.sleep(.fromMicroseconds(50), .awake) catch return;
        }
    }
};

fn sawLast(reader: *Reader, io: Io) bool {
    _ = io;
    return reader.seen.load(.acquire) == 20;
}

test "eight tasks provision versions 1 to 20 of one tenant" {
    const io = testing.io;
    var fake: FakeDriver = .init(testing.allocator);
    defer fake.deinit();
    var registry: Registry = .init(testing.allocator, io, fake.driver(), .{});
    defer registry.deinit(io);
    for ([_][]const u8{ "shared-1", "shared-2" }, [_][]const u8{ "fake://one", "fake://two" }) |id, uri| {
        try registry.registerConnection(io, id, .{ .uri = uri });
        try registry.connect(io, .root, id);
    }

    var storm: Storm = .{ .registry = &registry, .order = undefined };
    for (&storm.order, 1..) |*version, n| version.* = n;
    var prng: std.Random.DefaultPrng = .init(0x0d17_0007);
    prng.random().shuffle(u64, &storm.order);
    for (1..21) |version| storm.lengths[version] = (try std.fmt.bufPrint(&storm.names[version], "acme_v{d}", .{version})).len;

    var reader: Reader = .{ .registry = &registry };
    {
        var readers: Io.Group = .init;
        defer readers.cancel(io);
        try readers.concurrent(io, Reader.run, .{ &reader, io });
        {
            var writers: Io.Group = .init;
            defer writers.cancel(io);
            for (0..Storm.tasks) |k| try writers.concurrent(io, Storm.provision, .{ &storm, io, k });
            try writers.await(io);
        }
        // Until a session of the end state came.
        try eventually(io, &reader, sawLast);
        reader.stop.store(true, .release);
        try readers.await(io);
    }

    try testing.expectEqual(@as(usize, 0), storm.unexpected.load(.monotonic));
    try testing.expectEqual(@as(usize, 20), storm.applied.load(.monotonic) + storm.stale.load(.monotonic));
    try testing.expectEqual(@as(usize, 0), reader.problems);
    try testing.expect(reader.sessions > 0);
    // Version 20 is the end state: its database on its connection.
    var session = try registry.tenant(io, "acme");
    defer session.deinit(io);
    try testing.expectEqualStrings("acme_v20", session.database());
    try testing.expectEqual(@as(usize, 1), (try registry.connectionStats(io, "shared-1")).tenants);
    try testing.expectEqual(@as(usize, 0), (try registry.connectionStats(io, "shared-2")).tenants);
    const s = registry.stats(io);
    try testing.expectEqual(@as(usize, 1), s.tenants);
    try testing.expectEqual(@as(usize, 1), s.leases);
}
