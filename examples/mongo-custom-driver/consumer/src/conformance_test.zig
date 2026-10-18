//! The conformance suite of zefir-mongo on minidriver, the way an
//! application builds the driver: build.zig hands zefir-mongo and
//! zefir-core of this checkout to the driver's module, so the build has one
//! zefir-mongo. Layer S runs against `mongo.testing.FakeServer`; with
//! `-Dlive-uri`, layer L runs against that mongod too, fail points included.

const std = @import("std");
const mongo = @import("zefir-mongo");
const minidriver = @import("mongo-minidriver");
const build_options = @import("build_options");
const conformance = mongo.testing.conformance;

test "minidriver passes the conformance suite of zefir-mongo" {
    var harness: minidriver.testing.Harness = .{};
    const live: ?conformance.Options.Live = if (build_options.live_uri) |uri| .{ .uri = uri, .fail_points = true } else null;
    var report = try conformance.run(std.testing.io, std.testing.allocator, &harness, .{ .live = live });
    defer report.deinit();
    if (report.failedCount() > 0) {
        std.debug.print("{f}", .{&report});
        return error.TestUnexpectedResult;
    }
    // A driver on the wire takes every check: S16, which reads OP_MSG, and
    // with a live mongod all of layer L, the fail points of L7–L10 among
    // them. Without one, only layer L is skipped.
    try std.testing.expect(report.outcome(.s16) == .passed);
    const all = std.enums.values(conformance.Check).len;
    try std.testing.expectEqual(@as(usize, if (live != null) all else 21), report.passedCount());
}
