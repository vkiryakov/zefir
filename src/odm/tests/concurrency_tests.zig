//! The concurrency test of design §7.5 on odm.testing.FakeDriver: 32
//! tasks take sessions of three tenants and run insertOne, find with next,
//! and updateOne, while the test replaces a connection as a gate holds
//! calls, replaces one with a drain that runs out, removes a tenant,
//! provisions one tenant with versions 1 to 20 from 8 tasks, or shuts the
//! registry down with cursors open. Every replacement brings new settings,
//! since the same ones change nothing. After each: every generation was
//! opened, closed and freed once, no lease is left, and the allocator of
//! the test sees no leak. Every wait is a loop on the .awake clock.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const bson = @import("mongo-bson");
const odm = @import("../root.zig");
const support = @import("support.zig");
const FakeDriver = odm.testing.FakeDriver;
const Registry = odm.Registry;
const Outcome = support.Outcome;
const eventually = support.eventually;

const Note = struct {
    id: ?bson.ObjectId = null,
    n: i32 = 0,

    pub const odm_schema: odm.Schema(Note) = .{ .collection = "notes", .id = .id };
};

/// "c1" (fake://c1-0) serves the tenants a and b, "c2" (fake://c2-0) the
/// tenant c.
const tenants = [_][]const u8{ "a", "b", "c" };

fn connect(registry: *Registry, io: Io) !void {
    for ([_][]const u8{ "c1", "c2" }, [_][]const u8{ "fake://c1-0", "fake://c2-0" }) |id, uri| {
        try registry.registerConnection(io, id, .{ .uri = uri });
        try registry.connect(io, .root, id);
    }
}

fn bind(registry: *Registry, io: Io) !void {
    try connect(registry, io);
    for (tenants, [_][]const u8{ "c1", "c1", "c2" }) |tenant, id| {
        try registry.provisionTenant(io, .root, .{ .tenant = tenant, .connection = .{ .existing = id }, .database = tenant, .version = 1 });
    }
}

/// The work of the tasks: rounds of insertOne, find with next and
/// updateOne, each on a session of its own, until `stop`.
const Load = struct {
    registry: *Registry,
    /// The errors that the scenario allows.
    allowed: []const anyerror,
    /// Whether a session is one that the scenario may give.
    check: ?*const fn (session: *const odm.Session, io: Io) bool = null,
    stop: std.atomic.Value(bool) = .init(false),
    rounds: std.atomic.Value(usize) = .init(0),
    /// The rounds of the tenants of c1 on its first generation, and on a
    /// later one.
    old: std.atomic.Value(usize) = .init(0),
    new: std.atomic.Value(usize) = .init(0),
    errors: std.atomic.Value(usize) = .init(0),
    closed: std.atomic.Value(usize) = .init(0),
    unexpected: std.atomic.Value(usize) = .init(0),
    done: std.atomic.Value(usize) = .init(0),

    fn run(load: *Load, io: Io, tenant: []const u8) void {
        defer _ = load.done.fetchAdd(1, .release);
        while (!load.stop.load(.acquire)) {
            load.round(io, tenant) catch |err| load.failed(err);
            // A breath between rounds keeps the journal of the fake small.
            io.sleep(.fromMicroseconds(300), .awake) catch return;
        }
    }

    fn round(load: *Load, io: Io, tenant: []const u8) !void {
        var session = try load.registry.tenant(io, tenant);
        defer session.deinit(io);
        if (load.check) |check| if (!check(&session, io)) return error.TornBinding;
        const notes = session.collection(Note);
        _ = try notes.insertOne(io, .root, .{ .n = 1 });
        var cursor = try notes.find(io, .root, .{ .n = .{ .gte = 0 } }, .{ .batch_size = 10 });
        defer cursor.deinit(io);
        var buffer: [256]u8 = undefined;
        var fixed: std.heap.FixedBufferAllocator = .init(&buffer);
        while (try cursor.next(io, .root, fixed.allocator())) |_| {}
        _ = try notes.updateOne(io, .root, .{ .n = 1 }, .{ .inc = .{ .n = 1 } });
        _ = load.rounds.fetchAdd(1, .monotonic);
        if (!std.mem.eql(u8, tenant, "c")) {
            const on = if (session.generation.number == 1) &load.old else &load.new;
            _ = on.fetchAdd(1, .monotonic);
        }
    }

    fn failed(load: *Load, err: anyerror) void {
        _ = load.errors.fetchAdd(1, .monotonic);
        if (err == error.Closed) _ = load.closed.fetchAdd(1, .monotonic);
        for (load.allowed) |allowed| {
            if (allowed == err) return;
        }
        if (load.unexpected.fetchAdd(1, .monotonic) == 0) std.debug.print("unexpected error of a round: {t}\n", .{err});
    }

    /// Starts `n` tasks on the tenants `on`, in turn.
    fn start(load: *Load, group: *Io.Group, io: Io, n: usize, on: []const []const u8) !void {
        for (0..n) |i| try group.concurrent(io, run, .{ load, io, on[i % on.len] });
    }

    /// Stops the tasks, and waits until the `n` of them are done.
    fn finish(load: *Load, io: Io, n: usize) !void {
        load.stop.store(true, .release);
        try atLeast(io, &load.done, n);
    }
};

/// Until `counter` reaches `n`; error.Timeout after 10 s.
fn atLeast(io: Io, counter: *std.atomic.Value(usize), n: usize) !void {
    const give_up = Io.Clock.awake.now(io).addDuration(.fromSeconds(10));
    while (counter.load(.acquire) < n) {
        if (Io.Clock.awake.now(io).nanoseconds >= give_up.nanoseconds) {
            std.debug.print("{d} of {d} after 10 s\n", .{ counter.load(.acquire), n });
            return error.Timeout;
        }
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}

/// Every client that the fake opened, `n` of them, was closed once and
/// freed, and no cursor is left.
fn expectAllClosed(fake: *FakeDriver, io: Io, n: usize) !void {
    const counts = fake.counts(io);
    try testing.expectEqual(n, counts.opened);
    try testing.expectEqual(n, counts.closed);
    try testing.expectEqual(n, counts.close_calls);
    try testing.expectEqual(n, counts.freed);
    try testing.expectEqual(@as(usize, 0), counts.cursors);
}

fn replaceTask(o: *Outcome, r: *Registry, io: Io, id: []const u8, uri: []const u8) void {
    o.set(r.replaceConnection(io, .root, id, .{ .uri = uri }));
}

fn published(r: *Registry, io: Io) bool {
    const s = r.connectionStats(io, "c1") catch return false;
    return s.generation == 2;
}

test "sessions finish on the old generation while a replacement waits for them" {
    const io = testing.io;
    var fake: FakeDriver = .init(testing.allocator);
    defer fake.deinit();
    var gate: FakeDriver.Gate = .{};
    defer gate.open(io);
    try fake.plan("fake://c1-0", .{ .gate = &gate });
    {
        var registry: Registry = .init(testing.allocator, io, fake.driver(), .{});
        defer registry.deinit(io);
        try bind(&registry, io);
        var load: Load = .{ .registry = &registry, .allowed = &.{} };
        var replaced: Outcome = .{};
        {
            var group: Io.Group = .init;
            defer group.cancel(io);
            try load.start(&group, io, 32, &tenants);
            // Calls of the tenants a and b wait at the gate of c1.
            try gate.waitFor(io, 4);
            try group.concurrent(io, replaceTask, .{ &replaced, &registry, io, "c1", "fake://c1-1" });
            try eventually(io, &registry, published);
            {
                // A session taken now gets the new generation, and works.
                var a = try registry.tenant(io, "a");
                defer a.deinit(io);
                try testing.expectEqual(@as(u64, 2), a.generation.number);
                _ = try a.collection(Note).insertOne(io, .root, .{ .n = 2 });
            }
            // The replacement waits for the sessions of the old one.
            try testing.expect(!replaced.done.load(.acquire));
            try testing.expectEqual(@as(usize, 1), registry.stats(io).draining);
            gate.open(io);
            try (try replaced.wait(io));
            try atLeast(io, &load.new, 32);
            try load.finish(io, 32);
        }
        try testing.expectEqual(@as(usize, 0), load.unexpected.load(.monotonic));
        try testing.expectEqual(@as(usize, 0), load.errors.load(.monotonic));
        // The held calls finished on the old generation.
        try testing.expect(load.old.load(.monotonic) >= 4);
        const s = registry.stats(io);
        try testing.expectEqual(@as(usize, 0), s.leases);
        try testing.expectEqual(@as(usize, 0), s.draining);
        try testing.expectEqual(@as(usize, 0), s.forced);
        const counts = fake.counts(io);
        try testing.expectEqual(@as(usize, 3), counts.opened);
        try testing.expectEqual(@as(usize, 1), counts.closed);
        try testing.expectEqual(@as(usize, 1), counts.close_calls);
        try testing.expectEqual(@as(usize, 1), counts.freed);
    }
    try expectAllClosed(&fake, io, 3);
}

fn freedOne(fake: *FakeDriver, io: Io) bool {
    return fake.counts(io).freed >= 1;
}

test "a drain that runs out closes the calls of the old generation by force" {
    const io = testing.io;
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;
    var fake: FakeDriver = .init(testing.allocator);
    defer fake.deinit();
    var gate: FakeDriver.Gate = .{};
    defer gate.open(io);
    try fake.plan("fake://c1-0", .{ .gate = &gate });
    {
        var registry: Registry = .init(testing.allocator, io, fake.driver(), .{ .drain_timeout = .fromMilliseconds(100) });
        defer registry.deinit(io);
        try bind(&registry, io);
        // The calls of the old generation after its forced close.
        var load: Load = .{ .registry = &registry, .allowed = &.{error.Closed} };
        {
            var group: Io.Group = .init;
            defer group.cancel(io);
            try load.start(&group, io, 32, &tenants);
            try gate.waitFor(io, 4);
            const start = Io.Clock.awake.now(io);
            try registry.replaceConnection(io, .root, "c1", .{ .uri = "fake://c1-1" });
            try testing.expect(start.durationTo(Io.Clock.awake.now(io)).nanoseconds >= 100 * std.time.ns_per_ms);
            try testing.expectEqual(@as(usize, 1), registry.stats(io).forced);
            // The holders got Closed and gave their leases back; the last
            // one freed the old generation.
            try eventually(io, &fake, freedOne);
            try atLeast(io, &load.new, 32);
            try load.finish(io, 32);
        }
        try testing.expectEqual(@as(usize, 0), load.unexpected.load(.monotonic));
        try testing.expect(load.closed.load(.monotonic) >= 4);
        const s = registry.stats(io);
        try testing.expectEqual(@as(usize, 0), s.leases);
        try testing.expectEqual(@as(usize, 0), s.draining);
        const counts = fake.counts(io);
        try testing.expectEqual(@as(usize, 3), counts.opened);
        try testing.expectEqual(@as(usize, 1), counts.closed);
        try testing.expectEqual(@as(usize, 1), counts.freed);
    }
    try expectAllClosed(&fake, io, 3);
}

test "a tenant removed in the middle of its requests" {
    const io = testing.io;
    var fake: FakeDriver = .init(testing.allocator);
    defer fake.deinit();
    {
        var registry: Registry = .init(testing.allocator, io, fake.driver(), .{});
        defer registry.deinit(io);
        try bind(&registry, io);
        var load: Load = .{ .registry = &registry, .allowed = &.{error.TenantNotFound} };
        {
            var group: Io.Group = .init;
            defer group.cancel(io);
            try load.start(&group, io, 32, &tenants);
            try atLeast(io, &load.rounds, 64);
            try registry.removeTenant(io, "b");
            try testing.expectError(error.TenantNotFound, registry.tenant(io, "b"));
            // The tasks of b find it gone; those of a and c go on.
            try atLeast(io, &load.errors, 16);
            try atLeast(io, &load.rounds, load.rounds.load(.acquire) + 64);
            try load.finish(io, 32);
        }
        try testing.expectEqual(@as(usize, 0), load.unexpected.load(.monotonic));
        const s = registry.stats(io);
        try testing.expectEqual(@as(usize, 2), s.tenants);
        try testing.expectEqual(@as(usize, 2), s.connections.active);
        try testing.expectEqual(@as(usize, 0), s.leases);
    }
    try expectAllClosed(&fake, io, 2);
}

/// Provisionings of the tenant t, one version after another of `order`,
/// from the task's first one on, in steps of 8. Version v binds the
/// database "t{v}", on c1 when v is even, else on c2.
const Versions = struct {
    registry: *Registry,
    order: [20]u64,
    applied: std.atomic.Value(usize) = .init(0),
    stale: std.atomic.Value(usize) = .init(0),
    unexpected: std.atomic.Value(usize) = .init(0),
    done: std.atomic.Value(usize) = .init(0),

    fn run(vs: *Versions, io: Io, first: usize) void {
        defer _ = vs.done.fetchAdd(1, .release);
        var i = first;
        while (i < vs.order.len) : (i += 8) {
            const version = vs.order[i];
            var buffer: [16]u8 = undefined;
            const database = std.fmt.bufPrint(&buffer, "t{d}", .{version}) catch return;
            const id: []const u8 = if (version % 2 == 0) "c1" else "c2";
            if (vs.registry.provisionTenant(io, .root, .{ .tenant = "t", .connection = .{ .existing = id }, .database = database, .version = version })) |_| {
                _ = vs.applied.fetchAdd(1, .monotonic);
            } else |err| switch (err) {
                error.StaleVersion => _ = vs.stale.fetchAdd(1, .monotonic),
                else => if (vs.unexpected.fetchAdd(1, .monotonic) == 0) std.debug.print("unexpected error of a provisioning: {t}\n", .{err}),
            }
        }
    }
};

/// Whether the database of the session is that of one of the versions, on
/// the connection of that version: a binding is published whole.
fn ofAVersion(session: *const odm.Session, io: Io) bool {
    const name = session.database();
    if (name.len < 2 or name[0] != 't') return false;
    const version = std.fmt.parseInt(u64, name[1..], 10) catch return false;
    if (version < 1 or version > 20) return false;
    // The registry's lock guards the link of a generation to its connection.
    const r = session.registry;
    r.mutex.lockUncancelable(io);
    defer r.mutex.unlock(io);
    const c = session.generation.connection orelse return false;
    return std.mem.eql(u8, c.id, if (version % 2 == 0) "c1" else "c2");
}

test "versions 1 to 20 of one tenant from eight tasks while its sessions work" {
    const io = testing.io;
    var fake: FakeDriver = .init(testing.allocator);
    defer fake.deinit();
    {
        var registry: Registry = .init(testing.allocator, io, fake.driver(), .{});
        defer registry.deinit(io);
        try connect(&registry, io);
        var versions: Versions = .{ .registry = &registry, .order = undefined };
        for (&versions.order, 1..) |*v, n| v.* = n;
        var prng: std.Random.DefaultPrng = .init(0x0d0_0020);
        prng.random().shuffle(u64, &versions.order);
        // Before the first publication there is no tenant t.
        var load: Load = .{ .registry = &registry, .allowed = &.{error.TenantNotFound}, .check = ofAVersion };
        {
            var group: Io.Group = .init;
            defer group.cancel(io);
            try load.start(&group, io, 24, &.{"t"});
            for (0..8) |i| try group.concurrent(io, Versions.run, .{ &versions, io, i });
            try atLeast(io, &versions.done, 8);
            try atLeast(io, &load.rounds, load.rounds.load(.acquire) + 48);
            try load.finish(io, 24);
        }
        try testing.expectEqual(@as(usize, 0), versions.unexpected.load(.monotonic));
        try testing.expectEqual(@as(usize, 20), versions.applied.load(.monotonic) + versions.stale.load(.monotonic));
        try testing.expectEqual(@as(usize, 0), load.unexpected.load(.monotonic));
        try testing.expect(load.rounds.load(.monotonic) > 0);
        // The last version is the tenant's, whatever the order.
        {
            var t = try registry.tenant(io, "t");
            defer t.deinit(io);
            try testing.expectEqualStrings("t20", t.database());
            try testing.expectEqualStrings("c1", t.generation.connection.?.id);
        }
        try registry.provisionTenant(io, .root, .{ .tenant = "t", .connection = .{ .existing = "c1" }, .database = "t20", .version = 20 });
        try testing.expectError(error.StaleVersion, registry.provisionTenant(io, .root, .{ .tenant = "t", .connection = .{ .existing = "c2" }, .database = "t19", .version = 19 }));
        const s = registry.stats(io);
        try testing.expectEqual(@as(usize, 1), s.tenants);
        try testing.expectEqual(@as(usize, 0), s.leases);
    }
    try expectAllClosed(&fake, io, 2);
}

/// Tasks that each hold a cursor, without its session, until `release`.
const Holders = struct {
    registry: *Registry,
    release: Io.Event = .unset,
    opened: std.atomic.Value(usize) = .init(0),
    closed: std.atomic.Value(usize) = .init(0),
    unexpected: std.atomic.Value(usize) = .init(0),
    done: std.atomic.Value(usize) = .init(0),

    fn run(h: *Holders, io: Io, tenant: []const u8) void {
        defer _ = h.done.fetchAdd(1, .release);
        h.hold(io, tenant) catch |err| {
            if (h.unexpected.fetchAdd(1, .monotonic) == 0) std.debug.print("unexpected error of a holder: {t}\n", .{err});
        };
    }

    fn hold(h: *Holders, io: Io, tenant: []const u8) !void {
        var cursor = cursor: {
            var session = try h.registry.tenant(io, tenant);
            defer session.deinit(io);
            break :cursor try session.collection(Note).find(io, .root, .{}, .{});
        };
        defer cursor.deinit(io);
        _ = h.opened.fetchAdd(1, .release);
        const give_up = Io.Clock.awake.now(io).addDuration(.fromSeconds(10));
        while (!h.release.isSet()) {
            if (Io.Clock.awake.now(io).nanoseconds >= give_up.nanoseconds) return error.Timeout;
            h.release.waitTimeout(io, .{ .deadline = give_up.withClock(.awake) }) catch |err| switch (err) {
                error.Timeout => {},
                error.Canceled => return err,
            };
        }
        var buffer: [256]u8 = undefined;
        var fixed: std.heap.FixedBufferAllocator = .init(&buffer);
        if (cursor.next(io, .root, fixed.allocator())) |_| {
            return error.NotClosed;
        } else |err| switch (err) {
            error.Closed => _ = h.closed.fetchAdd(1, .monotonic),
            else => return err,
        }
    }
};

test "a shutdown with cursors open" {
    const io = testing.io;
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;
    var fake: FakeDriver = .init(testing.allocator);
    defer fake.deinit();
    {
        var registry: Registry = .init(testing.allocator, io, fake.driver(), .{});
        defer registry.deinit(io);
        try bind(&registry, io);
        // After the shutdown began, and in the generations it closed by
        // force.
        var load: Load = .{ .registry = &registry, .allowed = &.{ error.ShuttingDown, error.Closed } };
        var holders: Holders = .{ .registry = &registry };
        {
            var group: Io.Group = .init;
            defer group.cancel(io);
            try load.start(&group, io, 16, &tenants);
            for (0..8) |i| try group.concurrent(io, Holders.run, .{ &holders, io, tenants[i % tenants.len] });
            try atLeast(io, &holders.opened, 8);
            try atLeast(io, &load.rounds, 32);
            // The cursors keep both generations past the deadline.
            const result = registry.shutdown(io, .fromNow(io, .{ .raw = .fromMilliseconds(100), .clock = .awake }));
            try testing.expectError(error.ShutdownTimeout, result);
            try testing.expectError(error.ShuttingDown, registry.tenant(io, "a"));
            holders.release.set(io);
            try atLeast(io, &holders.done, 8);
            try load.finish(io, 16);
        }
        try testing.expectEqual(@as(usize, 0), holders.unexpected.load(.monotonic));
        try testing.expectEqual(@as(usize, 8), holders.closed.load(.monotonic));
        try testing.expectEqual(@as(usize, 0), load.unexpected.load(.monotonic));
        const s = registry.stats(io);
        try testing.expectEqual(@as(usize, 2), s.forced);
        try testing.expectEqual(@as(usize, 0), s.leases);
    }
    try expectAllClosed(&fake, io, 2);
}
