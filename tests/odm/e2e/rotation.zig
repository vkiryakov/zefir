//! New credentials of a connection on the fly, on mongo-auth (design Р48,
//! Р49), while tasks read and write through sessions of its tenant, a
//! session per operation:
//!
//! - a second user: `replaceConnection` with its uri and password, then
//!   the first user goes, once the call returned and the old generation is
//!   closed; three times, there and back, and no call fails;
//! - the same settings again change nothing;
//! - a new password of the same user, set in place: from then on the
//!   server refuses the old one to every new connection of the old
//!   generation, whose calls fail with `AuthenticationFailed` or
//!   `Unavailable` until it drains after the replacement. Every call after
//!   the return passes.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const bson = @import("mongo-bson");
const odm = @import("odm");
const mongo = @import("mongo");
const e2e = @import("root.zig");
const within = e2e.within;

/// The tenant's database, where its users live too.
const database = "odm_rot";
const user_a = "odm_rot_a";
const user_b = "odm_rot_b";
const uri_a = "mongodb://" ++ user_a ++ "@127.0.0.1:27118/" ++ database;
const uri_b = "mongodb://" ++ user_b ++ "@127.0.0.1:27118/" ++ database;
const roles = .{.{ .role = "readWrite", .db = database }};

const Note = struct {
    id: ?bson.ObjectId = null,
    owner: []const u8,
    n: i32 = 0,

    pub const odm_schema: odm.Schema(Note) = .{ .collection = "notes", .id = .id };
};

/// How the calls of the workers ended.
const Calls = struct {
    /// Whether the calls before the return of the replacement may fail
    /// with AuthenticationFailed and Unavailable: the window of a password
    /// changed in place.
    window: bool,
    stop: std.atomic.Value(bool) = .init(false),
    /// Set once the replacement returned: a call that sees it takes its
    /// session after the return, so it must pass.
    returned: std.atomic.Value(bool) = .init(false),
    ok: std.atomic.Value(u32) = .init(0),
    /// The failures in the window.
    auth_failed: std.atomic.Value(u32) = .init(0),
    unavailable: std.atomic.Value(u32) = .init(0),
    /// Any other failure, or one after the return.
    unexpected: std.atomic.Value(u32) = .init(0),

    fn record(calls: *Calls, result: anyerror!void, after: bool, d: *const odm.Diagnostics) void {
        result catch |err| {
            if (calls.window and !after) switch (err) {
                error.AuthenticationFailed => {
                    _ = calls.auth_failed.fetchAdd(1, .monotonic);
                    return;
                },
                error.Unavailable => {
                    _ = calls.unavailable.fetchAdd(1, .monotonic);
                    return;
                },
                else => {},
            };
            if (calls.unexpected.fetchAdd(1, .monotonic) == 0) {
                std.debug.print("  a call{s}: {t}: {s}\n", .{ if (after) " after the return" else "", err, d.message() });
            }
            return;
        };
        _ = calls.ok.fetchAdd(1, .monotonic);
    }
};

/// A task that calls through sessions of the tenant "rot" until told to
/// stop, a session per call: it writes, reads, changes and counts.
const Worker = struct {
    registry: *odm.Registry,
    index: usize,
    calls: *Calls,
    pause: Io.Duration,

    fn run(w: *Worker, io: Io) Io.Cancelable!void {
        var sequence: usize = 0;
        while (!w.calls.stop.load(.acquire)) : (sequence += 1) {
            // Read before the session is taken.
            const after = w.calls.returned.load(.acquire);
            var d: odm.Diagnostics = .{};
            w.calls.record(w.call(io, sequence, &d), after, &d);
            try io.sleep(w.pause, .awake);
        }
    }

    fn call(w: *Worker, io: Io, sequence: usize, d: *odm.Diagnostics) !void {
        var session = try w.registry.tenant(io, "rot");
        defer session.deinit(io);
        errdefer d.* = session.diagnostics().*;
        const notes = session.collection(Note);
        const ctx = within(io, .fromSeconds(10));
        switch ((w.index + sequence) % 4) {
            0 => _ = try notes.insertOne(io, ctx, .{ .owner = "worker", .n = @intCast(sequence % 1000) }),
            1 => {
                var buffer: [512]u8 = undefined;
                var memory: std.heap.FixedBufferAllocator = .init(&buffer);
                const seed = try notes.findOne(io, ctx, .{ .owner = "seed" }, .{}, memory.allocator()) orelse return error.TestSeedNotFound;
                try testing.expectEqualStrings("seed", seed.owner);
            },
            2 => {
                const changed = try notes.updateOne(io, ctx, .{ .owner = "seed" }, .{ .inc = .{ .n = 1 } });
                try testing.expectEqual(@as(u64, 1), changed.matched);
            },
            3 => _ = try notes.count(io, ctx, .{ .owner = "worker" }),
            else => unreachable,
        }
    }
};

/// A registry with the connection "rot" of `uri` and `password` and the
/// tenant "rot" on it, which holds the note "seed".
fn open(registry: *odm.Registry, io: Io, uri: []const u8, password: []const u8) !void {
    try registry.registerConnection(io, "rot", .{ .uri = uri, .password = password });
    try registry.connect(io, within(io, .fromSeconds(10)), "rot");
    try registry.provisionTenant(io, within(io, .fromSeconds(10)), .{ .tenant = "rot", .connection = .{ .existing = "rot" }, .database = database, .version = 1 });
    var session = try registry.tenant(io, "rot");
    defer session.deinit(io);
    _ = try session.collection(Note).insertOne(io, within(io, .fromSeconds(10)), .{ .owner = "seed" });
}

/// Starts `workers` on `registry`.
fn start(group: *Io.Group, io: Io, workers: []Worker, registry: *odm.Registry, calls: *Calls, pause: Io.Duration) !void {
    for (workers, 0..) |*w, i| {
        w.* = .{ .registry = registry, .index = i, .calls = calls, .pause = pause };
        try group.concurrent(io, Worker.run, .{ w, io });
    }
}

/// Nothing of the old generations is left: no lease out, none draining,
/// none closed by force.
fn expectSettled(registry: *odm.Registry, io: Io) !void {
    const stats = registry.stats(io);
    try testing.expectEqual(@as(usize, 0), stats.leases);
    try testing.expectEqual(@as(usize, 0), stats.draining);
    try testing.expectEqual(@as(usize, 0), stats.forced);
    try testing.expectEqual(@as(usize, 0), (try registry.connectionStats(io, "rot")).draining);
}

test "rotation by a second user loses no call" {
    try e2e.onZio(rotation);
}

fn rotation(io: Io) !void {
    var auth: e2e.Admin = undefined;
    try auth.openAuth(io);
    defer auth.close();
    try auth.dropDatabase(io, database);
    defer auth.dropDatabaseAtEnd(io, database);
    try auth.dropUserIfAny(io, database, user_b);
    defer auth.dropUserAtEnd(io, database, user_b);
    try auth.freshUser(io, database, user_a, "rot-a-1", roles);
    defer auth.dropUserAtEnd(io, database, user_a);

    var driver: mongo.OdmDriver = .init(testing.allocator);
    var registry: odm.Registry = .init(testing.allocator, io, driver.driver(), .{});
    defer registry.deinit(io);
    try open(&registry, io, uri_a, "rot-a-1");

    var calls: Calls = .{ .window = false };
    var workers: [16]Worker = undefined;
    var group: Io.Group = .init;
    defer group.cancel(io);
    try start(&group, io, &workers, &registry, &calls, .fromMilliseconds(1));

    // There and back: the next user is made, the connection moves to it,
    // and the user before it goes once the old generation is closed.
    const Step = struct { user: []const u8, password: []const u8, uri: []const u8, gone: []const u8 };
    const steps = [_]Step{
        .{ .user = user_b, .password = "rot-b-1", .uri = uri_b, .gone = user_a },
        .{ .user = user_a, .password = "rot-a-2", .uri = uri_a, .gone = user_b },
        .{ .user = user_b, .password = "rot-b-2", .uri = uri_b, .gone = user_a },
    };
    for (steps, 2..) |step, generation| {
        // The calls go through the current generation for a while.
        try io.sleep(.fromMilliseconds(300), .awake);
        try auth.createUser(io, database, step.user, step.password, roles);
        var d: odm.Diagnostics = .{};
        registry.replaceConnection(io, within(io, .fromSeconds(10)), "rot", .{ .uri = step.uri, .password = step.password, .diagnostics = &d }) catch |err| {
            std.debug.print("  the replacement with {s}: {t}: {s}\n", .{ step.user, err, d.message() });
            return err;
        };
        try testing.expectEqual(@as(u64, generation), (try registry.connectionStats(io, "rot")).generation);
        try auth.dropUser(io, database, step.gone);
    }
    try io.sleep(.fromMilliseconds(300), .awake);
    calls.stop.store(true, .release);
    try group.await(io);

    std.debug.print("  {d} calls through 3 rotations, {d} failed\n", .{ calls.ok.load(.monotonic), calls.unexpected.load(.monotonic) });
    try testing.expectEqual(@as(u32, 0), calls.unexpected.load(.monotonic));
    try testing.expect(calls.ok.load(.monotonic) > 0);
    try expectSettled(&registry, io);
    const stats = try registry.connectionStats(io, "rot");
    try testing.expectEqual(odm.ConnectionState.active, stats.state);
    try testing.expectEqual(@as(u64, 4), stats.generation);
}

test "the same rotation again changes nothing" {
    try e2e.onZio(sameAgain);
}

fn sameAgain(io: Io) !void {
    var auth: e2e.Admin = undefined;
    try auth.openAuth(io);
    defer auth.close();
    try auth.dropDatabase(io, database);
    defer auth.dropDatabaseAtEnd(io, database);
    try auth.freshUser(io, database, user_a, "rot-a-1", roles);
    defer auth.dropUserAtEnd(io, database, user_a);
    try auth.freshUser(io, database, user_b, "rot-b-1", roles);
    defer auth.dropUserAtEnd(io, database, user_b);

    var driver: mongo.OdmDriver = .init(testing.allocator);
    var registry: odm.Registry = .init(testing.allocator, io, driver.driver(), .{});
    defer registry.deinit(io);
    try open(&registry, io, uri_a, "rot-a-1");

    try registry.replaceConnection(io, within(io, .fromSeconds(10)), "rot", .{ .uri = uri_b, .password = "rot-b-1" });
    try testing.expectEqual(@as(u64, 2), (try registry.connectionStats(io, "rot")).generation);
    // The event of the rotation delivered again: no new generation.
    for (0..2) |_| {
        try registry.replaceConnection(io, within(io, .fromSeconds(10)), "rot", .{ .uri = uri_b, .password = "rot-b-1" });
        try testing.expectEqual(@as(u64, 2), (try registry.connectionStats(io, "rot")).generation);
        try expectSettled(&registry, io);
    }
    // Other settings make one.
    try registry.replaceConnection(io, within(io, .fromSeconds(10)), "rot", .{ .uri = uri_a, .password = "rot-a-1" });
    try testing.expectEqual(@as(u64, 3), (try registry.connectionStats(io, "rot")).generation);
    try registry.replaceConnection(io, within(io, .fromSeconds(10)), "rot", .{ .uri = uri_a, .password = "rot-a-1" });
    try testing.expectEqual(@as(u64, 3), (try registry.connectionStats(io, "rot")).generation);
    try expectSettled(&registry, io);

    var session = try registry.tenant(io, "rot");
    defer session.deinit(io);
    try testing.expectEqual(@as(u64, 1), try session.collection(Note).count(io, within(io, .fromSeconds(10)), .{ .owner = "seed" }));
}

test "a new password of the same user has a window of errors" {
    try e2e.onZio(newPassword);
}

fn newPassword(io: Io) !void {
    // A connection idle for 50 ms is closed at its next check-out, and
    // the workers pause 60 ms between calls: each call opens a connection,
    // so the old generation meets the new password at once.
    const uri = uri_a ++ "?maxIdleTimeMS=50";
    var auth: e2e.Admin = undefined;
    try auth.openAuth(io);
    defer auth.close();
    try auth.dropDatabase(io, database);
    defer auth.dropDatabaseAtEnd(io, database);
    try auth.freshUser(io, database, user_a, "rot-a-1", roles);
    defer auth.dropUserAtEnd(io, database, user_a);

    var driver: mongo.OdmDriver = .init(testing.allocator);
    var registry: odm.Registry = .init(testing.allocator, io, driver.driver(), .{});
    defer registry.deinit(io);
    try open(&registry, io, uri, "rot-a-1");

    var calls: Calls = .{ .window = true };
    var workers: [8]Worker = undefined;
    var group: Io.Group = .init;
    defer group.cancel(io);
    try start(&group, io, &workers, &registry, &calls, .fromMilliseconds(60));
    try io.sleep(.fromMilliseconds(300), .awake);

    // From now on the server refuses the old password to new connections.
    try auth.changePassword(io, database, user_a, "rot-a-2");
    try io.sleep(.fromMilliseconds(400), .awake);
    var d: odm.Diagnostics = .{};
    registry.replaceConnection(io, within(io, .fromSeconds(10)), "rot", .{ .uri = uri, .password = "rot-a-2", .diagnostics = &d }) catch |err| {
        std.debug.print("  the replacement with the new password: {t}: {s}\n", .{ err, d.message() });
        return err;
    };
    calls.returned.store(true, .release);
    try testing.expectEqual(@as(u64, 2), (try registry.connectionStats(io, "rot")).generation);
    const at_return = calls.ok.load(.monotonic);
    try io.sleep(.fromMilliseconds(400), .awake);
    calls.stop.store(true, .release);
    try group.await(io);

    std.debug.print("  the window: {d} calls failed, {d} with AuthenticationFailed and {d} with Unavailable; {d} calls passed, {d} of them after the return\n", .{
        calls.auth_failed.load(.monotonic) + calls.unavailable.load(.monotonic),
        calls.auth_failed.load(.monotonic),
        calls.unavailable.load(.monotonic),
        calls.ok.load(.monotonic),
        calls.ok.load(.monotonic) - at_return,
    });
    try testing.expectEqual(@as(u32, 0), calls.unexpected.load(.monotonic));
    try testing.expect(calls.ok.load(.monotonic) > at_return);
    try expectSettled(&registry, io);
}
