//! Tests of the set commands of `redis.cmd` against
//! `redis.testing.FakeServer`: each with its exact arguments and its reply
//! read from the RESP3 form a server gives it, a set `~` for SMEMBERS and
//! the operations of sets, and the checks before anything goes out. Every
//! test runs under a time limit of 5 s.

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
pub const covered = [_][]const u8{ "sadd", "srem", "sismember", "smembers", "scard", "spop", "sinter", "sunion", "sdiff", "sscan" };

test "the set commands send their arguments and read their replies: counts, a bool, sets, a member or null, a page of SSCAN" {
    try within5s(testing.io, sets, .{testing.io});
}

fn sets(io: Io) !void {
    var server: FakeServer = try .start(testing.allocator, io, &.{
        .expect(.{ "SADD", "k", "a", "b" }, .{ .integer = 2 }),
        .expect(.{ "SREM", "k", "a" }, .{ .integer = 1 }),
        .expect(.{ "SISMEMBER", "k", "a" }, .{ .integer = 1 }),
        .expect(.{ "SMEMBERS", "k" }, .{ .set = &.{ .{ .string = "a" }, .{ .string = "b" } } }),
        .expect(.{ "SCARD", "k" }, .{ .integer = 2 }),
        .expect(.{ "SPOP", "k" }, .{ .string = "a" }),
        .expect(.{ "SPOP", "k" }, .nil),
        .expect(.{ "SINTER", "a", "b" }, .{ .set = &.{.{ .string = "x" }} }),
        .expect(.{ "SUNION", "a", "b" }, .{ .set = &.{ .{ .string = "x" }, .{ .string = "y" } } }),
        .expect(.{ "SDIFF", "a", "b" }, .{ .set = &.{} }),
        .expect(.{ "SSCAN", "k", "0" }, .{ .array = &.{
            .{ .string = "0" },
            .{ .array = &.{ .{ .string = "a" }, .{ .string = "b" } } },
        } }),
        .expect(.{ "SSCAN", "k", "5", "MATCH", "a*", "COUNT", "100" }, .{ .array = &.{ .{ .string = "9" }, .{ .array = &.{} } } }),
    });
    defer server.stop(io);
    var t: Fixture = undefined;
    try t.init(io, &server);
    defer t.deinit();

    try testing.expectEqual(@as(u64, 2), try t.run(io, cmd.sadd("k", &.{ "a", "b" })));
    try testing.expectEqual(@as(u64, 1), try t.run(io, cmd.srem("k", &.{"a"})));
    try testing.expect(try t.run(io, cmd.sismember("k", "a")));
    try testing.expectEqualDeep(@as([]const []const u8, &.{ "a", "b" }), try t.run(io, cmd.smembers([]const u8, "k")));
    try testing.expectEqual(@as(u64, 2), try t.run(io, cmd.scard("k")));
    try testing.expectEqualDeep(@as(?[]const u8, "a"), try t.run(io, cmd.spop([]const u8, "k")));
    try testing.expectEqualDeep(@as(?[]const u8, null), try t.run(io, cmd.spop([]const u8, "k")));
    try testing.expectEqualDeep(@as([]const []const u8, &.{"x"}), try t.run(io, cmd.sinter([]const u8, &.{ "a", "b" })));
    try testing.expectEqualDeep(@as([]const []const u8, &.{ "x", "y" }), try t.run(io, cmd.sunion([]const u8, &.{ "a", "b" })));
    try testing.expectEqualDeep(@as([]const []const u8, &.{}), try t.run(io, cmd.sdiff([]const u8, &.{ "a", "b" })));
    try testing.expectEqualDeep(redis.ScanPage([]const u8){ .cursor = 0, .items = &.{ "a", "b" } }, try t.run(io, cmd.sscan("k", .{})));
    try testing.expectEqualDeep(redis.ScanPage([]const u8){ .cursor = 9, .items = &.{} }, try t.run(io, cmd.sscan("k", .{ .cursor = 5, .match = "a*", .count = 100 })));
    try server.finish(io);
}

test "no members and no keys are InvalidArgument, and nothing goes out" {
    try within5s(testing.io, refused, .{testing.io});
}

fn refused(io: Io) !void {
    var server: FakeServer = try .start(testing.allocator, io, &.{});
    defer server.stop(io);
    var t: Fixture = undefined;
    try t.init(io, &server);
    defer t.deinit();

    try testing.expectError(error.InvalidArgument, t.run(io, cmd.sadd("k", &.{})));
    try testing.expectEqualStrings("redis.cmd.sadd: no members: SADD takes one or more", t.d.message());
    try testing.expectError(error.InvalidArgument, t.run(io, cmd.srem("k", &.{})));
    try testing.expectEqualStrings("redis.cmd.srem: no members: SREM takes one or more", t.d.message());
    try testing.expectError(error.InvalidArgument, t.run(io, cmd.sinter([]const u8, &.{})));
    try testing.expectEqualStrings("redis.cmd.sinter: no keys: SINTER takes one or more", t.d.message());
    try testing.expectError(error.InvalidArgument, t.run(io, cmd.sunion([]const u8, &.{})));
    try testing.expectError(error.InvalidArgument, t.run(io, cmd.sdiff([]const u8, &.{})));
    try testing.expectEqual(@as(usize, 0), server.received(io));
}
