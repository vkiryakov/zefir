//! Tests of the pub/sub command of `redis.cmd` against
//! `redis.testing.FakeServer`: PUBLISH with its exact arguments, a channel
//! and a message of any bytes, and its reply. Every test runs under a time
//! limit of 5 s.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const redis = @import("../root.zig");
const cmd = redis.cmd;
const FakeServer = redis.testing.FakeServer;
const Fixture = @import("fixture.zig").Fixture;
const within5s = @import("../tests/time_limit.zig").within5s;

/// The functions of `redis.cmd` that this file tests, for the check that
/// every function of the catalog has a test.
pub const covered = [_][]const u8{"publish"};

test "publish sends the channel and the message, any bytes, and reads how many subscribers got it" {
    try within5s(testing.io, publish, .{testing.io});
}

fn publish(io: Io) !void {
    var server: FakeServer = try .start(testing.allocator, io, &.{
        .expect(.{ "PUBLISH", "orders", "new" }, .{ .integer = 2 }),
        .expect(.{ "PUBLISH", "a\r\nb\x00c", "x\x00y\r\n" }, .{ .integer = 0 }),
    });
    defer server.stop(io);
    var t: Fixture = undefined;
    try t.init(io, &server);
    defer t.deinit();

    try testing.expectEqual(@as(u64, 2), try t.run(io, cmd.publish("orders", "new")));
    try testing.expectEqual(@as(u64, 0), try t.run(io, cmd.publish("a\r\nb\x00c", "x\x00y\r\n")));
    try server.finish(io);
}
