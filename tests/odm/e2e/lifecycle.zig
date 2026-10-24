//! The lifecycle of tenants and of the registry on mongod: a tenant
//! removed while tasks call through its sessions, and a shutdown while
//! sessions and a cursor are still out.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const bson = @import("mongo-bson");
const odm = @import("odm");
const mongo = @import("mongo");
const e2e = @import("root.zig");
const within = e2e.within;

const Note = struct {
    id: ?bson.ObjectId = null,
    owner: []const u8,

    pub const odm_schema: odm.Schema(Note) = .{ .collection = "notes", .id = .id };
};

fn existing(tenant_id: []const u8, database: []const u8, version: u64) odm.Provision {
    return .{ .tenant = tenant_id, .connection = .{ .existing = "shared" }, .database = database, .version = version };
}

/// How the calls through the sessions of one tenant ended.
const Tally = struct {
    ok: std.atomic.Value(u32) = .init(0),
    not_found: std.atomic.Value(u32) = .init(0),
    /// A call that took its session after the removal and passed, or any
    /// other error.
    unexpected: std.atomic.Value(u32) = .init(0),

    fn record(t: *Tally, result: anyerror!void, after: bool, d: *const odm.Diagnostics) void {
        if (result) |_| {
            if (!after) {
                _ = t.ok.fetchAdd(1, .monotonic);
                return;
            }
            if (t.unexpected.fetchAdd(1, .monotonic) == 0) std.debug.print("  a session after the removal\n", .{});
        } else |err| {
            if (err == error.TenantNotFound) {
                _ = t.not_found.fetchAdd(1, .monotonic);
                return;
            }
            if (t.unexpected.fetchAdd(1, .monotonic) == 0) std.debug.print("  a call: {t}: {s}\n", .{ err, d.message() });
        }
    }
};

/// A task that calls through sessions of its tenant until told to stop, a
/// session per call.
const Caller = struct {
    registry: *odm.Registry,
    tenant_id: []const u8,
    index: usize,
    tally: *Tally,
    stop: *const std.atomic.Value(bool),
    /// Set once the tenant is removed.
    removed: *const std.atomic.Value(bool),

    fn run(c: *Caller, io: Io) Io.Cancelable!void {
        var sequence: usize = 0;
        while (!c.stop.load(.acquire)) : (sequence += 1) {
            // Read before the session is taken.
            const after = c.removed.load(.acquire);
            var d: odm.Diagnostics = .{};
            c.tally.record(c.call(io, sequence, &d), after, &d);
            try io.sleep(.fromMilliseconds(1), .awake);
        }
    }

    fn call(c: *Caller, io: Io, sequence: usize, d: *odm.Diagnostics) !void {
        var session = try c.registry.tenant(io, c.tenant_id);
        defer session.deinit(io);
        errdefer d.* = session.diagnostics().*;
        const notes = session.collection(Note);
        const ctx = within(io, .fromSeconds(10));
        if ((c.index + sequence) % 2 == 0) {
            _ = try notes.insertOne(io, ctx, .{ .owner = c.tenant_id });
        } else {
            _ = try notes.count(io, ctx, .{});
        }
    }
};

test "removing a tenant in the middle of requests" {
    try e2e.onZio(removal);
}

fn removal(io: Io) !void {
    const databases = [_][]const u8{ "odm_life_keep", "odm_life_gone" };
    var admin: e2e.Admin = undefined;
    try admin.openPlain(io);
    defer admin.close();
    for (databases) |name| try admin.dropDatabase(io, name);
    defer for (databases) |name| admin.dropDatabaseAtEnd(io, name);

    var driver: mongo.OdmDriver = .init(testing.allocator);
    var registry: odm.Registry = .init(testing.allocator, io, driver.driver(), .{});
    defer registry.deinit(io);
    try registry.registerConnection(io, "shared", .{ .uri = e2e.servers.plain });
    try registry.provisionTenant(io, within(io, .fromSeconds(10)), existing("keep", "odm_life_keep", 1));
    try registry.provisionTenant(io, within(io, .fromSeconds(10)), existing("gone", "odm_life_gone", 1));

    var stop: std.atomic.Value(bool) = .init(false);
    var removed: std.atomic.Value(bool) = .init(false);
    const never: std.atomic.Value(bool) = .init(false);
    var keep: Tally = .{};
    var gone: Tally = .{};
    var callers: [16]Caller = undefined;
    var group: Io.Group = .init;
    defer group.cancel(io);
    for (&callers, 0..) |*c, i| {
        const of_gone = i % 2 == 1;
        c.* = .{
            .registry = &registry,
            .tenant_id = if (of_gone) "gone" else "keep",
            .index = i,
            .tally = if (of_gone) &gone else &keep,
            .stop = &stop,
            .removed = if (of_gone) &removed else &never,
        };
        try group.concurrent(io, Caller.run, .{ c, io });
    }
    try io.sleep(.fromMilliseconds(300), .awake);
    {
        // A session taken before the removal works on after it, in the
        // tenant's database.
        var held = try registry.tenant(io, "gone");
        defer held.deinit(io);
        try registry.removeTenant(io, "gone");
        removed.store(true, .release);
        try testing.expectError(error.TenantNotFound, registry.tenant(io, "gone"));
        try testing.expectError(error.TenantNotFound, registry.removeTenant(io, "gone"));
        _ = try held.collection(Note).insertOne(io, within(io, .fromSeconds(10)), .{ .owner = "held" });
        try testing.expectEqualStrings("odm_life_gone", held.database());
    }
    try io.sleep(.fromMilliseconds(300), .awake);
    stop.store(true, .release);
    try group.await(io);

    std.debug.print("  keep: {d} calls passed; gone: {d} passed, {d} found no tenant\n", .{ keep.ok.load(.monotonic), gone.ok.load(.monotonic), gone.not_found.load(.monotonic) });
    try testing.expectEqual(@as(u32, 0), keep.unexpected.load(.monotonic) + keep.not_found.load(.monotonic));
    try testing.expectEqual(@as(u32, 0), gone.unexpected.load(.monotonic));
    try testing.expect(keep.ok.load(.monotonic) > 0);
    try testing.expect(gone.ok.load(.monotonic) > 0);
    try testing.expect(gone.not_found.load(.monotonic) > 0);
    const holder = admin.collection("odm_life_gone", "notes").countDocuments(io, e2e.op(io), .{ .owner = "held" }, .{ .allocator = testing.allocator });
    try testing.expectEqual(@as(u64, 1), try holder);
    var stats = registry.stats(io);
    try testing.expectEqual(@as(usize, 1), stats.tenants);
    try testing.expectEqual(@as(usize, 0), stats.leases);
    try testing.expectEqual(@as(usize, 1), (try registry.connectionStats(io, "shared")).tenants);

    // The registry keeps no memory of a removed tenant: a provisioning of
    // any version binds it again.
    try registry.provisionTenant(io, within(io, .fromSeconds(10)), existing("gone", "odm_life_gone", 1));
    {
        var again = try registry.tenant(io, "gone");
        defer again.deinit(io);
        try testing.expect(try again.collection(Note).count(io, within(io, .fromSeconds(10)), .{}) > 0);
    }
    // A connection that tenants are bound to cannot go.
    try testing.expectError(error.ConnectionInUse, registry.removeConnection(io, "shared"));
    stats = registry.stats(io);
    try testing.expectEqual(@as(usize, 2), stats.tenants);
    try testing.expectEqual(@as(usize, 0), stats.leases);
}

test "shutdown with live sessions" {
    try e2e.onZio(shutdownWithLeases);
}

fn shutdownWithLeases(io: Io) !void {
    const database = "odm_life";
    var admin: e2e.Admin = undefined;
    try admin.openPlain(io);
    defer admin.close();
    try admin.dropDatabase(io, database);
    defer admin.dropDatabaseAtEnd(io, database);

    var driver: mongo.OdmDriver = .init(testing.allocator);
    var registry: odm.Registry = .init(testing.allocator, io, driver.driver(), .{});
    defer registry.deinit(io);
    try registry.registerConnection(io, "shared", .{ .uri = e2e.servers.plain });
    try registry.provisionTenant(io, within(io, .fromSeconds(10)), existing("life", database, 1));
    const ctx = within(io, .fromSeconds(10));
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    // Out at the shutdown: a session with a cursor in the middle of its
    // documents, and a session that no call went through.
    var held = try registry.tenant(io, "life");
    defer held.deinit(io);
    const notes = held.collection(Note);
    for (0..3) |_| _ = try notes.insertOne(io, ctx, .{ .owner = "life" });
    var cursor = try notes.find(io, ctx, .{}, .{ .batch_size = 1 });
    defer cursor.deinit(io);
    _ = (try cursor.next(io, ctx, arena.allocator())).?;
    var idle = try registry.tenant(io, "life");
    defer idle.deinit(io);

    const began = Io.Clock.awake.now(io);
    try testing.expectError(error.ShutdownTimeout, registry.shutdown(io, .fromNow(io, .{ .raw = .fromMilliseconds(300), .clock = .awake })));
    const took = began.durationTo(Io.Clock.awake.now(io)).toMilliseconds();
    try testing.expect(took >= 250 and took < 5000);

    // Their generation was closed by force: their holders get Closed.
    try testing.expectError(error.Closed, notes.count(io, ctx, .{}));
    try testing.expectError(error.Closed, cursor.next(io, ctx, arena.allocator()));
    try testing.expectError(error.Closed, idle.collection(Note).insertOne(io, ctx, .{ .owner = "late" }));
    try testing.expectError(error.ShuttingDown, registry.tenant(io, "life"));
    const stats = registry.stats(io);
    try testing.expectEqual(@as(usize, 1), stats.forced);
    try testing.expectEqual(@as(usize, 3), stats.leases);
    // A second shutdown gives the result of the first.
    try testing.expectError(error.ShutdownTimeout, registry.shutdown(io, .fromNow(io, .{ .raw = .fromMilliseconds(0), .clock = .awake })));
    // Nothing after the close reached the server.
    const count = admin.collection(database, "notes").countDocuments(io, e2e.op(io), .{}, .{ .allocator = testing.allocator });
    try testing.expectEqual(@as(u64, 3), try count);
}
