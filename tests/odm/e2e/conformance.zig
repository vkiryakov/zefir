//! The conformance suite of zefir-odm on `mongo.OdmDriver` against
//! mongod: groups C and D, each check on a fresh database of mongo-plain,
//! and a login that mongo-auth refuses.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const odm = @import("odm");
const mongo = @import("mongo");
const e2e = @import("root.zig");
const conformance = odm.testing.conformance;

/// The appName of the clients of the checks, which the fail point of
/// `stall` names, so that no other client of mongo-plain sees it.
const app = "odm-conformance";

const Harness = struct {
    /// A client of mongo-plain: drops the databases, sets the fail point.
    admin: *e2e.Admin,
    driver: mongo.OdmDriver = undefined,
    buffer: [64]u8 = undefined,
    stalled: bool = false,

    pub fn setUp(h: *Harness, io: Io, gpa: std.mem.Allocator) !conformance.Setup {
        const database = try e2e.freshName(&h.buffer, "conf");
        try h.admin.dropDatabase(io, database);
        h.driver = .init(gpa);
        h.stalled = false;
        return .{ .driver = h.driver.driver(), .config = .{ .uri = e2e.servers.plain ++ "/?appName=" ++ app }, .database = database };
    }

    pub fn tearDown(h: *Harness, io: Io, setup: conformance.Setup) void {
        if (h.stalled) h.admin.failPointOff(io);
        h.admin.dropDatabase(io, setup.database) catch |err| std.debug.print("drop of {s}: {t}\n", .{ setup.database, err });
    }

    pub fn badCredentials(h: *Harness) odm.ConnectionConfig {
        _ = h;
        return .{ .uri = "mongodb://odm_nobody@127.0.0.1:27118/admin", .password = conformance.secret };
    }

    pub fn stall(h: *Harness, io: Io, setup: conformance.Setup) !void {
        _ = setup;
        h.stalled = true;
        try h.admin.failPoint(io, .{ .failCommands = .{"find"}, .appName = app, .blockConnection = true, .blockTimeMS = 5000 });
    }
};

test "mongo.OdmDriver passes groups C and D on mongod" {
    try e2e.onZio(passes);
}

fn passes(io: Io) !void {
    var admin: e2e.Admin = undefined;
    try admin.openPlain(io);
    defer admin.close();
    var harness: Harness = .{ .admin = &admin };
    var report = try conformance.run(io, testing.allocator, &harness, .{});
    defer report.deinit();
    if (report.failedCount() > 0) {
        std.debug.print("{f}", .{&report});
        return error.TestUnexpectedResult;
    }
    try testing.expectEqual(@as(usize, 20), report.passedCount());
}
