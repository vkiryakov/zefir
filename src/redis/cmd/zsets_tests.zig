//! Tests of the sorted set commands of `redis.cmd` against
//! `redis.testing.FakeServer`: each with its exact arguments and its reply
//! read from the RESP3 form a server gives it, scores as doubles;
//! WITHSCORES from the type of the reply, the bounds of a range by score
//! in the order REV takes them, and the checks before anything goes out.
//! Every test runs under a time limit of 5 s.

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
pub const covered = [_][]const u8{ "zadd", "zincrby", "zscore", "zrank", "zrevrank", "zrem", "zcard", "zcount", "zrange", "zrangeByScore", "zpopmin", "zpopmax", "zremrangebyscore", "zremrangebyrank", "zscan" };

const Scored = redis.Scored([]const u8);

test "the sorted set commands send their arguments and read their replies: scores as doubles, ranks or null, ranges with WITHSCORES from the type, a popped member or null, a page of ZSCAN" {
    try within5s(testing.io, zsets, .{testing.io});
}

fn zsets(io: Io) !void {
    var server: FakeServer = try .start(testing.allocator, io, &.{
        .expect(.{ "ZADD", "leaders", "12.5", "ann" }, .{ .integer = 1 }),
        .expect(.{ "ZADD", "leaders", "XX", "GT", "CH", "12.5", "ann", "3", "bob" }, .{ .integer = 2 }),
        .expect(.{ "ZADD", "leaders", "NX", "-inf", "cy" }, .{ .integer = 1 }),
        .expect(.{ "ZINCRBY", "k", "1.5", "ann" }, .{ .double = 14 }),
        .expect(.{ "ZSCORE", "k", "ann" }, .{ .double = 12.5 }),
        .expect(.{ "ZSCORE", "k", "zed" }, .nil),
        .expect(.{ "ZRANK", "k", "ann" }, .{ .integer = 0 }),
        .expect(.{ "ZREVRANK", "k", "zed" }, .nil),
        .expect(.{ "ZREM", "k", "ann", "bob" }, .{ .integer = 2 }),
        .expect(.{ "ZCARD", "k" }, .{ .integer = 3 }),
        .expect(.{ "ZCOUNT", "k", "(1.5", "+inf" }, .{ .integer = 2 }),
        .expect(.{ "ZCOUNT", "k", "-inf", "2" }, .{ .integer = 1 }),
        .expect(.{ "ZRANGE", "k", "0", "-1" }, .{ .array = &.{ .{ .string = "ann" }, .{ .string = "bob" } } }),
        .expect(.{ "ZRANGE", "k", "0", "9", "REV", "WITHSCORES" }, .{ .array = &.{
            .{ .array = &.{ .{ .string = "ann" }, .{ .double = 12.5 } } },
            .{ .array = &.{ .{ .string = "bob" }, .{ .double = 3 } } },
        } }),
        .expect(.{ "ZRANGE", "k", "+inf", "1", "BYSCORE", "REV", "LIMIT", "0", "10" }, .{ .array = &.{.{ .string = "ann" }} }),
        .expect(.{ "ZRANGE", "k", "(1", "5", "BYSCORE", "LIMIT", "20", "5", "WITHSCORES" }, .{ .array = &.{
            .{ .array = &.{ .{ .string = "bob" }, .{ .double = 3 } } },
        } }),
        .expect(.{ "ZPOPMIN", "k" }, .{ .array = &.{ .{ .string = "ann" }, .{ .double = 12.5 } } }),
        .expect(.{ "ZPOPMAX", "k" }, .{ .array = &.{ .{ .string = "bob" }, .{ .double = 3 } } }),
        .expect(.{ "ZPOPMIN", "gone" }, .{ .array = &.{} }),
        .expect(.{ "ZREMRANGEBYSCORE", "k", "-inf", "(5" }, .{ .integer = 4 }),
        .expect(.{ "ZREMRANGEBYRANK", "k", "0", "-11" }, .{ .integer = 0 }),
        .expect(.{ "ZSCAN", "k", "0", "MATCH", "a*" }, .{ .array = &.{
            .{ .string = "0" },
            .{ .array = &.{ .{ .string = "ann" }, .{ .string = "12.5" }, .{ .string = "bob" }, .{ .string = "3" } } },
        } }),
    });
    defer server.stop(io);
    var t: Fixture = undefined;
    try t.init(io, &server);
    defer t.deinit();

    try testing.expectEqual(@as(u64, 1), try t.run(io, cmd.zadd("leaders", &.{.{ .member = "ann", .score = 12.5 }}, .{})));
    try testing.expectEqual(@as(u64, 2), try t.run(io, cmd.zadd("leaders", &.{ .{ .member = "ann", .score = 12.5 }, .{ .member = "bob", .score = 3 } }, .{ .only = .present, .compare = .greater, .changed = true })));
    try testing.expectEqual(@as(u64, 1), try t.run(io, cmd.zadd("leaders", &.{.{ .member = "cy", .score = -std.math.inf(f64) }}, .{ .only = .absent })));
    try testing.expectEqual(@as(f64, 14), try t.run(io, cmd.zincrby("k", 1.5, "ann")));
    try testing.expectEqual(@as(?f64, 12.5), try t.run(io, cmd.zscore("k", "ann")));
    try testing.expectEqual(@as(?f64, null), try t.run(io, cmd.zscore("k", "zed")));
    try testing.expectEqual(@as(?u64, 0), try t.run(io, cmd.zrank("k", "ann")));
    try testing.expectEqual(@as(?u64, null), try t.run(io, cmd.zrevrank("k", "zed")));
    try testing.expectEqual(@as(u64, 2), try t.run(io, cmd.zrem("k", &.{ "ann", "bob" })));
    try testing.expectEqual(@as(u64, 3), try t.run(io, cmd.zcard("k")));
    try testing.expectEqual(@as(u64, 2), try t.run(io, cmd.zcount("k", .{ .exclusive = 1.5 }, .max)));
    try testing.expectEqual(@as(u64, 1), try t.run(io, cmd.zcount("k", .min, .{ .inclusive = 2 })));
    try testing.expectEqualDeep(@as([]const []const u8, &.{ "ann", "bob" }), try t.run(io, cmd.zrange([]const u8, "k", 0, -1, .{})));
    const both: []const Scored = &.{ .{ .member = "ann", .score = 12.5 }, .{ .member = "bob", .score = 3 } };
    try testing.expectEqualDeep(both, try t.run(io, cmd.zrange(Scored, "k", 0, 9, .{ .rev = true })));
    try testing.expectEqualDeep(@as([]const []const u8, &.{"ann"}), try t.run(io, cmd.zrangeByScore([]const u8, "k", .{ .inclusive = 1 }, .max, .{ .rev = true, .limit = .{ .count = 10 } })));
    try testing.expectEqualDeep(both[1..], try t.run(io, cmd.zrangeByScore(Scored, "k", .{ .exclusive = 1 }, .{ .inclusive = 5 }, .{ .limit = .{ .offset = 20, .count = 5 } })));
    try testing.expectEqualDeep(@as(?Scored, both[0]), try t.run(io, cmd.zpopmin([]const u8, "k")));
    try testing.expectEqualDeep(@as(?Scored, both[1]), try t.run(io, cmd.zpopmax([]const u8, "k")));
    try testing.expectEqualDeep(@as(?Scored, null), try t.run(io, cmd.zpopmin([]const u8, "gone")));
    try testing.expectEqual(@as(u64, 4), try t.run(io, cmd.zremrangebyscore("k", .min, .{ .exclusive = 5 })));
    try testing.expectEqual(@as(u64, 0), try t.run(io, cmd.zremrangebyrank("k", 0, -11)));
    try testing.expectEqualDeep(redis.ScanPage(Scored){ .cursor = 0, .items = both }, try t.run(io, cmd.zscan("k", .{ .match = "a*" })));
    try server.finish(io);
}

test "NX with GT or LT, a score or a bound that is NaN and an empty list are InvalidArgument, and nothing goes out" {
    try within5s(testing.io, refused, .{testing.io});
}

fn refused(io: Io) !void {
    var server: FakeServer = try .start(testing.allocator, io, &.{});
    defer server.stop(io);
    var t: Fixture = undefined;
    try t.init(io, &server);
    defer t.deinit();
    const nan = std.math.nan(f64);

    try testing.expectError(error.InvalidArgument, t.run(io, cmd.zadd("k", &.{.{ .member = "ann", .score = 1 }}, .{ .only = .absent, .compare = .less })));
    try testing.expectEqualStrings("redis.cmd.zadd: .only = .absent (NX) and .compare (GT or LT) together, which a server refuses: NX adds new members only, and GT and LT update those it has", t.d.message());
    try testing.expectError(error.InvalidArgument, t.run(io, cmd.zadd("k", &.{ .{ .member = "ann", .score = 1 }, .{ .member = "bob", .score = nan } }, .{})));
    try testing.expectEqualStrings("redis.cmd.zadd: members[1].score is NaN, which a server does not take", t.d.message());
    try testing.expectError(error.InvalidArgument, t.run(io, cmd.zadd("k", &.{}, .{})));
    try testing.expectEqualStrings("redis.cmd.zadd: no members: ZADD takes one or more", t.d.message());
    try testing.expectError(error.InvalidArgument, t.run(io, cmd.zincrby("k", nan, "ann")));
    try testing.expectEqualStrings("redis.cmd.zincrby: by is NaN, which a server does not take", t.d.message());
    try testing.expectError(error.InvalidArgument, t.run(io, cmd.zrem("k", &.{})));
    try testing.expectEqualStrings("redis.cmd.zrem: no members: ZREM takes one or more", t.d.message());
    try testing.expectError(error.InvalidArgument, t.run(io, cmd.zcount("k", .{ .inclusive = nan }, .max)));
    try testing.expectEqualStrings("redis.cmd.zcount: min is NaN, which a server does not take", t.d.message());
    try testing.expectError(error.InvalidArgument, t.run(io, cmd.zremrangebyscore("k", .min, .{ .exclusive = nan })));
    try testing.expectEqualStrings("redis.cmd.zremrangebyscore: max is NaN, which a server does not take", t.d.message());
    try testing.expectError(error.InvalidArgument, t.run(io, cmd.zrangeByScore([]const u8, "k", .{ .exclusive = nan }, .max, .{})));
    try testing.expectEqualStrings("redis.cmd.zrangeByScore: min is NaN, which a server does not take", t.d.message());
    try testing.expectEqual(@as(usize, 0), server.received(io));
}
