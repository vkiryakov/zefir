//! A driver is "zefir compatible" when it passes the conformance suite of
//! odm, `odm.testing.conformance`. The author of a driver runs it in the
//! tests of the driver's package, through a harness that sets the driver
//! up for each check. Here the driver is `odm.testing.FakeDriver`, which
//! has no server, so the suite runs group C, the rules of the contract; a
//! driver with a server runs group D, the data, too.

const std = @import("std");
const odm = @import("odm");
const conformance = odm.testing.conformance;
const FakeDriver = odm.testing.FakeDriver;

/// What the suite needs of the driver: a fresh setup for each check, and
/// the hooks that the driver can give.
const Harness = struct {
    fake: FakeDriver = undefined,
    gate: FakeDriver.Gate = .{},

    /// The driver, the settings of a server that works, and an empty
    /// database on it. The driver takes its memory from `gpa`, which the
    /// suite counts: what is left after `tearDown` is a leak.
    pub fn setUp(h: *Harness, io: std.Io, gpa: std.mem.Allocator) !conformance.Setup {
        _ = io;
        h.fake = .init(gpa);
        errdefer h.fake.deinit();
        h.gate = .{};
        // The plans of the fake stand for a server that is not there and
        // for a login that the server refuses.
        try h.fake.plan("fake://away", .{ .connects = &.{error.Unavailable} });
        try h.fake.plan("fake://refused", .{ .connects = &.{error.AuthenticationFailed} });
        return .{ .driver = h.fake.driver(), .config = .{ .uri = "fake://shop" }, .database = "conformance" };
    }

    /// Frees what `setUp` made; the harness of a driver with a server drops
    /// the database here too.
    pub fn tearDown(h: *Harness, io: std.Io, setup: conformance.Setup) void {
        _ = setup;
        h.gate.open(io);
        h.fake.deinit();
    }

    /// A login that the server refuses. Its password is the one that the
    /// suite looks for in every text of the driver.
    pub fn badCredentials(h: *Harness) odm.ConnectionConfig {
        _ = h;
        return .{ .uri = "fake://refused", .password = conformance.secret };
    }

    /// A server that is not there.
    pub fn unreachableServer(h: *Harness) odm.ConnectionConfig {
        _ = h;
        return .{ .uri = "fake://away" };
    }

    /// Makes the next find of the clients of `setup` hang on the server,
    /// so that the suite can check that `close` cuts a call in flight.
    pub fn stall(h: *Harness, io: std.Io, setup: conformance.Setup) !void {
        _ = io;
        try h.fake.plan(setup.config.uri, .{ .gate = &h.gate });
    }
};

test "the driver is zefir compatible" {
    var harness: Harness = .{};
    var report = try conformance.run(std.testing.io, std.testing.allocator, &harness, .{ .data = false });
    defer report.deinit();
    if (report.failedCount() > 0) {
        std.debug.print("{f}", .{&report});
        return error.TestUnexpectedResult;
    }
    try std.testing.expectEqual(@as(usize, 10), report.passedCount());
}
