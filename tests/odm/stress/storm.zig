//! A storm over 20 tenants on two connections of mongo-auth, for 20 s.
//! 32 tasks take a session of a tenant and call through it, a session per
//! call: an insert, a find of one document, an update, a count, and a
//! cursor over several batches. Meanwhile each connection is replaced every
//! 200 ms, by turns with two users (the same settings again would change
//! nothing, design Р49), and a task removes a tenant, provisions it again
//! on the other connection, delivers the same event again, then an older
//! one. Then the same load, with a shutdown in the middle of it.
//!
//! A call may fail only with TenantNotFound (its tenant was just removed),
//! StaleVersion (the older event), ShuttingDown or Closed; any other error
//! fails the test. At the end no lease is out, no generation drains or was
//! closed by force, and the test runner sees all the memory back.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const core = @import("core");
const bson = @import("mongo-bson");
const odm = @import("odm");
const mongo = @import("mongo");
const e2e = @import("e2e");
const stress = @import("root.zig");
const within = e2e.within;

const tenant_count = 20;
const workers = 32;
const storm_time: Io.Duration = .fromSeconds(20);
/// How long the load of the shutdown runs before the shutdown comes.
const load_time: Io.Duration = .fromSeconds(2);
const replace_every: Io.Duration = .fromMilliseconds(200);

/// The database of the users of the storm.
const users_database = "odm_storm";

const User = struct { name: []const u8, password: []const u8, uri: []const u8 };

/// The users that each connection takes by turns. Every replacement opens
/// a client and its pool anew, so a pool keeps 4 connections at most.
const users = [2]User{
    .{ .name = "odm_storm_a", .password = "odm-storm-a-pass", .uri = "mongodb://odm_storm_a@127.0.0.1:27118/" ++ users_database ++ "?maxPoolSize=4" },
    .{ .name = "odm_storm_b", .password = "odm-storm-b-pass", .uri = "mongodb://odm_storm_b@127.0.0.1:27118/" ++ users_database ++ "?maxPoolSize=4" },
};
const connections = [2][]const u8{ "storm-1", "storm-2" };

/// The tenants t1…t20, and their databases odm_storm_1…odm_storm_20.
const tenants = names("t{d}");
const databases = names("odm_storm_{d}");

fn names(comptime format: []const u8) [tenant_count][]const u8 {
    comptime {
        var out: [tenant_count][]const u8 = undefined;
        for (&out, 1..) |*name, i| name.* = std.fmt.comptimePrint(format, .{i});
        return out;
    }
}

const Role = struct { role: []const u8, db: []const u8 };

/// readWrite on each database of the storm.
const roles = roles: {
    var out: [tenant_count]Role = undefined;
    for (&out, databases) |*role, database| role.* = .{ .role = "readWrite", .db = database };
    break :roles out;
};

const Note = struct {
    id: ?bson.ObjectId = null,
    owner: []const u8,
    n: i32 = 0,

    pub const odm_schema: odm.Schema(Note) = .{ .collection = "notes", .id = .id };
};

/// How the calls of the storm ended.
const Outcomes = struct {
    calls: std.atomic.Value(u64) = .init(0),
    tenant_not_found: std.atomic.Value(u64) = .init(0),
    stale_version: std.atomic.Value(u64) = .init(0),
    shutting_down: std.atomic.Value(u64) = .init(0),
    closed: std.atomic.Value(u64) = .init(0),
    /// Any other error: a bug. The first one is printed.
    unexpected: std.atomic.Value(u64) = .init(0),

    fn failed(o: *Outcomes, err: anyerror, what: []const u8, d: ?*const odm.Diagnostics) void {
        const counter = switch (err) {
            error.TenantNotFound => &o.tenant_not_found,
            error.StaleVersion => &o.stale_version,
            error.ShuttingDown => &o.shutting_down,
            error.Closed => &o.closed,
            else => &o.unexpected,
        };
        const first = counter.fetchAdd(1, .monotonic) == 0;
        if (first and counter == &o.unexpected) std.debug.print("  {s}: {t}: {s}\n", .{ what, err, if (d) |x| x.message() else "" });
    }
};

/// The registry under the storm, and what its tasks did.
const Storm = struct {
    registry: *odm.Registry,
    outcomes: Outcomes = .{},
    stop: std.atomic.Value(bool) = .init(false),
    replacements: [2]std.atomic.Value(u32) = .{ .init(0), .init(0) },
    removals: std.atomic.Value(u32) = .init(0),

    /// The workers, a replacer for each connection, and the provisioner.
    fn start(s: *Storm, group: *Io.Group, io: Io) !void {
        for (0..workers) |index| try group.concurrent(io, worker, .{ s, io, index });
        for (0..connections.len) |which| try group.concurrent(io, replacer, .{ s, io, which });
        try group.concurrent(io, provisioner, .{ s, io });
    }

    fn worker(s: *Storm, io: Io, index: usize) Io.Cancelable!void {
        var sequence: usize = 0;
        while (!s.stop.load(.acquire)) : (sequence += 1) {
            var d: odm.Diagnostics = .{};
            if (s.call(io, index, sequence, &d)) |_| {
                _ = s.outcomes.calls.fetchAdd(1, .monotonic);
            } else |err| {
                s.outcomes.failed(err, "a call", &d);
                // After a shutdown, every call would get it.
                if (err == error.ShuttingDown) return;
            }
            try io.sleep(.fromMilliseconds(1), .awake);
        }
    }

    /// One call through a session of its own, of a tenant and a kind that
    /// change from call to call.
    fn call(s: *Storm, io: Io, index: usize, sequence: usize, d: *odm.Diagnostics) !void {
        var session = try s.registry.tenant(io, tenants[(index * 7 + sequence) % tenant_count]);
        defer session.deinit(io);
        const notes = session.collection(Note);
        const ctx = within(io, .fromSeconds(10));
        if (sequence % 5 == 4) return readBatches(notes, io, ctx, d);
        operate(notes, io, ctx, index, sequence) catch |err| {
            d.* = session.diagnostics().*;
            return err;
        };
    }

    fn operate(notes: odm.Collection(Note), io: Io, ctx: core.Context, index: usize, sequence: usize) !void {
        switch (sequence % 5) {
            0 => _ = try notes.insertOne(io, ctx, .{ .owner = "storm", .n = @intCast(index) }),
            1 => {
                var buffer: [512]u8 = undefined;
                var memory: std.heap.FixedBufferAllocator = .init(&buffer);
                _ = try notes.findOne(io, ctx, .{ .owner = "seed" }, .{}, memory.allocator()) orelse return error.TestSeedNotFound;
            },
            2 => {
                const changed = try notes.updateOne(io, ctx, .{ .owner = "seed" }, .{ .inc = .{ .n = 1 } });
                if (changed.matched != 1) return error.TestSeedNotFound;
            },
            3 => _ = try notes.count(io, ctx, .{ .owner = "storm" }),
            else => unreachable,
        }
    }

    /// A cursor over several batches, which holds a lease of its own until
    /// its deinit.
    fn readBatches(notes: odm.Collection(Note), io: Io, ctx: core.Context, d: *odm.Diagnostics) !void {
        var cursor = try notes.find(io, ctx, .{}, .{ .batch_size = 2, .limit = 6 });
        defer cursor.deinit(io);
        var buffer: [2048]u8 = undefined;
        var memory: std.heap.FixedBufferAllocator = .init(&buffer);
        while (cursor.next(io, ctx, memory.allocator()) catch |err| {
            d.* = cursor.diagnostics().*;
            return err;
        }) |_| {}
    }

    /// Every 200 ms, replaces the connection `which` with the other user.
    fn replacer(s: *Storm, io: Io, which: usize) Io.Cancelable!void {
        // storm-1 begins with the first user, storm-2 with the second.
        var current = which;
        while (!s.stop.load(.acquire)) {
            try io.sleep(replace_every, .awake);
            const next = 1 - current;
            var d: odm.Diagnostics = .{};
            const settings: odm.ConnectionConfig = .{ .uri = users[next].uri, .password = users[next].password, .diagnostics = &d };
            if (s.registry.replaceConnection(io, within(io, .fromSeconds(10)), connections[which], settings)) |_| {
                current = next;
                _ = s.replacements[which].fetchAdd(1, .monotonic);
            } else |err| {
                s.outcomes.failed(err, "a replacement", &d);
                if (err == error.ShuttingDown) return;
            }
        }
    }

    /// Every 50 ms, one tenant after another: it is removed, and 20 ms
    /// later provisioned on the other connection, by its next event, which
    /// comes twice, and then by an older one.
    fn provisioner(s: *Storm, io: Io) Io.Cancelable!void {
        var versions: [tenant_count]u64 = @splat(1);
        var on: [tenant_count]usize = undefined;
        for (&on, 0..) |*which, t| which.* = t % connections.len;
        var round: usize = 0;
        while (!s.stop.load(.acquire)) : (round += 1) {
            try io.sleep(.fromMilliseconds(50), .awake);
            const t = round % tenant_count;
            if (s.registry.removeTenant(io, tenants[t])) |_| {
                _ = s.removals.fetchAdd(1, .monotonic);
            } else |err| {
                s.outcomes.failed(err, "a removal", null);
                if (err == error.ShuttingDown) return;
            }
            // The tasks find no tenant for a while.
            try io.sleep(.fromMilliseconds(20), .awake);
            versions[t] += 1;
            on[t] = 1 - on[t];
            var d: odm.Diagnostics = .{};
            const event: odm.Provision = .{
                .tenant = tenants[t],
                .connection = .{ .existing = connections[on[t]] },
                .database = databases[t],
                .version = versions[t],
                .diagnostics = &d,
            };
            for (0..2) |_| {
                s.registry.provisionTenant(io, within(io, .fromSeconds(10)), event) catch |err| {
                    s.outcomes.failed(err, "a provisioning", &d);
                    if (err == error.ShuttingDown) return;
                };
            }
            var older = event;
            older.version -= 1;
            if (s.registry.provisionTenant(io, within(io, .fromSeconds(10)), older)) |_| {
                s.outcomes.failed(error.TestOlderEventApplied, "an older event", &d);
            } else |err| {
                s.outcomes.failed(err, "an older event", &d);
                if (err == error.ShuttingDown) return;
            }
        }
    }

    fn report(s: *Storm) void {
        const o = &s.outcomes;
        std.debug.print("  {d} calls passed; failed: TenantNotFound {d}, StaleVersion {d}, ShuttingDown {d}, Closed {d}, other {d}; {d} and {d} replacements, {d} removals\n", .{
            o.calls.load(.monotonic),
            o.tenant_not_found.load(.monotonic),
            o.stale_version.load(.monotonic),
            o.shutting_down.load(.monotonic),
            o.closed.load(.monotonic),
            o.unexpected.load(.monotonic),
            s.replacements[0].load(.monotonic),
            s.replacements[1].load(.monotonic),
            s.removals.load(.monotonic),
        });
    }
};

/// Registers and connects the two connections, provisions the tenants on
/// them by turns, and writes the note "seed" into each database.
fn setUp(registry: *odm.Registry, io: Io) !void {
    for (connections, users) |id, user| {
        try registry.registerConnection(io, id, .{ .uri = user.uri, .password = user.password });
        try registry.connect(io, within(io, .fromSeconds(10)), id);
    }
    for (tenants, databases, 0..) |tenant_id, database, t| {
        try registry.provisionTenant(io, within(io, .fromSeconds(10)), .{ .tenant = tenant_id, .connection = .{ .existing = connections[t % connections.len] }, .database = database, .version = 1 });
        var session = try registry.tenant(io, tenant_id);
        defer session.deinit(io);
        _ = try session.collection(Note).insertOne(io, within(io, .fromSeconds(10)), .{ .owner = "seed" });
    }
}

test "a storm over 20 tenants on two connections" {
    try stress.onZio(storm);
}

fn storm(io: Io) !void {
    var auth: e2e.Admin = undefined;
    try auth.openAuth(io);
    defer auth.close();
    for (databases) |name| try auth.dropDatabase(io, name);
    defer for (databases) |name| auth.dropDatabaseAtEnd(io, name);
    for (users) |user| try auth.freshUser(io, users_database, user.name, user.password, @as([]const Role, &roles));
    defer for (users) |user| auth.dropUserAtEnd(io, users_database, user.name);

    var driver: mongo.OdmDriver = .init(testing.allocator);
    var registry: odm.Registry = .init(testing.allocator, io, driver.driver(), .{});
    defer registry.deinit(io);
    try setUp(&registry, io);

    var s: Storm = .{ .registry = &registry };
    var group: Io.Group = .init;
    defer group.cancel(io);
    try s.start(&group, io);
    try io.sleep(storm_time, .awake);
    s.stop.store(true, .release);
    try group.await(io);

    s.report();
    try testing.expectEqual(@as(u64, 0), s.outcomes.unexpected.load(.monotonic));
    try testing.expect(s.outcomes.calls.load(.monotonic) > 0);
    try testing.expect(s.outcomes.tenant_not_found.load(.monotonic) > 0);
    try testing.expect(s.outcomes.stale_version.load(.monotonic) > 0);
    try testing.expect(s.removals.load(.monotonic) > 0);
    for (connections, &s.replacements) |id, *replaced| {
        const n = replaced.load(.monotonic);
        try testing.expect(n >= 10);
        try testing.expectEqual(@as(u64, n) + 1, (try registry.connectionStats(io, id)).generation);
    }
    const stats = registry.stats(io);
    try testing.expectEqual(@as(usize, 0), stats.leases);
    try testing.expectEqual(@as(usize, 0), stats.draining);
    try testing.expectEqual(@as(usize, 0), stats.forced);
    try testing.expectEqual(@as(usize, tenant_count), stats.tenants);
    try testing.expectEqual(@as(usize, 2), stats.connections.active);
}

test "shutdown under load" {
    try stress.onZio(shutdownUnderLoad);
}

fn shutdownUnderLoad(io: Io) !void {
    var auth: e2e.Admin = undefined;
    try auth.openAuth(io);
    defer auth.close();
    for (databases) |name| try auth.dropDatabase(io, name);
    defer for (databases) |name| auth.dropDatabaseAtEnd(io, name);
    for (users) |user| try auth.freshUser(io, users_database, user.name, user.password, @as([]const Role, &roles));
    defer for (users) |user| auth.dropUserAtEnd(io, users_database, user.name);

    var driver: mongo.OdmDriver = .init(testing.allocator);
    var registry: odm.Registry = .init(testing.allocator, io, driver.driver(), .{});
    defer registry.deinit(io);
    try setUp(&registry, io);

    var s: Storm = .{ .registry = &registry };
    var group: Io.Group = .init;
    defer group.cancel(io);
    try s.start(&group, io);
    try io.sleep(load_time, .awake);
    const began = Io.Clock.awake.now(io);
    const result = registry.shutdown(io, .fromNow(io, .{ .raw = .fromSeconds(10), .clock = .awake }));
    const took = began.durationTo(Io.Clock.awake.now(io));
    // The tasks stop at their next call, on ShuttingDown; `stop` ends
    // those that sleep.
    s.stop.store(true, .release);
    try group.await(io);

    s.report();
    std.debug.print("  the shutdown took {d} ms\n", .{took.toMilliseconds()});
    // Every lease came back before the deadline.
    try result;
    try testing.expectEqual(@as(u64, 0), s.outcomes.unexpected.load(.monotonic));
    try testing.expect(s.outcomes.calls.load(.monotonic) > 0);
    try testing.expect(s.outcomes.shutting_down.load(.monotonic) > 0);
    const stats = registry.stats(io);
    try testing.expectEqual(@as(usize, 0), stats.leases);
    try testing.expectEqual(@as(usize, 0), stats.draining);
    try testing.expectEqual(@as(usize, 0), stats.forced);
}
