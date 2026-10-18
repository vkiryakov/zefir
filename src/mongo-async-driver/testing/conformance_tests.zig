//! The conformance suite of zefir-mongo on the native driver: every check
//! of layer S against the scripted server of the check, which
//! `mongo.testing.FakeServer` serves over loopback, S16 for drivers on the
//! wire among them. Layer L needs a live mongod: tests/mongo-async-driver
//! runs it, with fail points.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const mongo = @import("mongo");
const conformance = mongo.testing.conformance;
const Client = @import("../Client.zig");

/// A fresh native driver on the target of each check, connected.
pub const Harness = struct {
    driver: Client = undefined,

    pub fn setUp(h: *Harness, io: Io, gpa: std.mem.Allocator, target: conformance.Target) !mongo.Client {
        const uri = switch (target) {
            .scripted => |s| s.uri,
            .live => |l| l.uri,
        };
        h.driver = try .init(gpa, io, .{ .uri = uri });
        errdefer h.driver.deinit();
        try h.driver.connect(io, .root, null);
        return h.driver.client();
    }

    pub fn close(h: *Harness, io: Io) void {
        h.driver.close(io);
    }

    pub fn tearDown(h: *Harness, io: Io) void {
        _ = io;
        h.driver.deinit();
    }
};

test "the native driver keeps the contract of zefir-mongo: every check of layer S, S16 among them; layer L is skipped without a live mongod" {
    var harness: Harness = .{};
    var report = try conformance.run(testing.io, testing.allocator, &harness, .{});
    defer report.deinit();
    if (report.failedCount() > 0) {
        std.debug.print("{f}", .{&report});
        return error.TestUnexpectedResult;
    }
    try testing.expectEqualStrings("zefir-mongo-async-driver", report.driver_name);
    try testing.expectEqual(conformance.Outcome.passed, report.outcome(.s16));
    try testing.expectEqual(@as(usize, 21), report.passedCount());
    try testing.expectEqual(@as(usize, 10), report.skippedCount());
}
