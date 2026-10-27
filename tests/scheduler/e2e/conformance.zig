//! The conformance suite of zefir-scheduler on `mongo.SchedulerStore`
//! against mongo-plain: each check on a fresh database, with the TTL
//! monitor of mongod waking every second. Once straight to the server,
//! and once through a proxy that loses the replies S17 asks to lose.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const scheduler = @import("scheduler");
const mongo = @import("mongo");
const e2e = @import("root.zig");
const Proxy = @import("Proxy.zig");
const conformance = scheduler.testing.conformance;

const Harness = struct {
    /// A client of mongo-plain: drops the databases, sets the parameter.
    admin: *e2e.Admin,
    /// The client of the stores.
    client: *mongo.Client,
    store: mongo.SchedulerStore = undefined,
    buffer: [64]u8 = undefined,
    database: []const u8 = "",

    pub fn setUp(h: *Harness, io: Io, gpa: std.mem.Allocator) !conformance.Setup {
        h.database = try e2e.freshName(&h.buffer, "conformance");
        try h.admin.dropDatabase(io, h.database);
        // The TTL monitor wakes every 60 s by default: once a second, an
        // expired record goes within the expiry_lag below.
        try h.admin.command(io, "admin", .{ .setParameter = 1, .ttlMonitorSleepSecs = 1 });
        h.store = try .init(gpa, io, h.client, .{ .database = h.database });
        errdefer h.store.deinit();
        var d: mongo.Diagnostics = .{};
        h.store.diagnostics = &d;
        defer h.store.diagnostics = null;
        h.store.ensureIndexes(io, e2e.within(io, .fromSeconds(30))) catch |err| {
            std.debug.print("ensureIndexes of {s}: {t}: {s}\n", .{ h.database, err, d.message() });
            return err;
        };
        return .{ .store = h.store.store(), .expiry_lag = .fromSeconds(10) };
    }

    pub fn tearDown(h: *Harness, io: Io, setup: conformance.Setup) void {
        _ = setup;
        h.admin.dropDatabase(io, h.database) catch |err| std.debug.print("drop of {s}: {t}\n", .{ h.database, err });
        h.store.deinit();
    }
};

/// The harness of the suite through a proxy that loses replies on
/// demand: the client of the stores goes through it.
const Lossy = struct {
    plain: Harness,
    proxy: *Proxy,

    pub fn setUp(h: *Lossy, io: Io, gpa: std.mem.Allocator) !conformance.Setup {
        return h.plain.setUp(io, gpa);
    }

    pub fn tearDown(h: *Lossy, io: Io, setup: conformance.Setup) void {
        h.plain.tearDown(io, setup);
    }

    /// The next write command of `op` reaches mongod, and its reply is
    /// lost; of a claim, its second findAndModify, so that the claim holds
    /// a record already. The loss clears the client's pool, and the store
    /// reads the record again on the probe of the pool: the proxy waits
    /// until a probe may go.
    pub fn loseNextReply(h: *Lossy, io: Io, op: scheduler.testing.Op) !void {
        try h.proxy.settle(io, .fromMilliseconds(600));
        h.proxy.loseReply(if (op == .claim) 2 else 1);
    }
};

test "mongo.SchedulerStore passes the conformance suite on mongo-plain" {
    try e2e.onZio(passes);
}

fn passes(io: Io) !void {
    var admin: e2e.Admin = undefined;
    try admin.open(io, e2e.servers.plain);
    defer admin.close();
    var client: mongo.Client = try .init(testing.allocator, io, .{ .uri = e2e.servers.plain });
    defer client.deinit();
    try client.connect(io, e2e.within(io, .fromSeconds(30)), null);
    var harness: Harness = .{ .admin = &admin, .client = &client };
    var report = try conformance.run(io, testing.allocator, &harness, .{});
    defer report.deinit();
    if (report.failedCount() > 0) {
        std.debug.print("{f}", .{&report});
        return error.TestUnexpectedResult;
    }
    // S17 needs lost replies: the test below.
    try testing.expectEqual(@as(usize, 21), report.passedCount());
    try testing.expectEqualStrings("the harness has no loseNextReply", switch (report.outcome(.s17)) {
        .skipped => |why| why,
        else => return error.TestUnexpectedResult,
    });
}

test "mongo.SchedulerStore passes the conformance suite with lost replies" {
    try e2e.onZio(passesWithLostReplies);
}

fn passesWithLostReplies(io: Io) !void {
    var admin: e2e.Admin = undefined;
    try admin.open(io, e2e.servers.plain);
    defer admin.close();
    // The proxy runs on the test's own Io, whatever runtime the client is
    // on.
    var proxy: Proxy = undefined;
    try proxy.start(testing.io, testing.allocator, e2e.servers.plain_port);
    defer proxy.stop();
    var buffer: [96]u8 = undefined;
    var client: mongo.Client = try .init(testing.allocator, io, .{ .uri = try proxy.uri(&buffer, "appName=scheduler-e2e-lossy") });
    defer client.deinit();
    try client.connect(io, e2e.within(io, .fromSeconds(30)), null);
    var harness: Lossy = .{ .plain = .{ .admin = &admin, .client = &client }, .proxy = &proxy };
    var report = try conformance.run(io, testing.allocator, &harness, .{});
    defer report.deinit();
    if (report.failedCount() > 0 or report.passedCount() != 22) {
        std.debug.print("{f}", .{&report});
        return error.TestUnexpectedResult;
    }
    // S17 loses eight replies: of two creates, an update, a renewal, three
    // finishes and a claim.
    try testing.expectEqual(@as(u32, 8), proxy.lostReplies());
}
