//! Tests of the key commands of `redis.cmd` against
//! `redis.testing.FakeServer`: DEL, UNLINK, EXISTS, PEXPIRE, PERSIST,
//! PTTL, TYPE, RENAME, a page of SCAN and PING, each with its exact
//! arguments and its reply read from the RESP3 form a server gives it,
//! and the checks before anything goes out. Every test runs under a time
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
pub const covered = [_][]const u8{ "del", "unlink", "exists", "expire", "persist", "ttl", "keyType", "rename", "scan", "ping" };

test "the key commands send their arguments and read their replies: counts, bools, a time to live, a type, a page of SCAN" {
    try within5s(testing.io, keys, .{testing.io});
}

fn keys(io: Io) !void {
    var server: FakeServer = try .start(testing.allocator, io, &.{
        .expect(.{ "DEL", "a", "b" }, .{ .integer = 2 }),
        .expect(.{ "UNLINK", "a", "b" }, .{ .integer = 1 }),
        .expect(.{ "EXISTS", "a", "a" }, .{ .integer = 2 }),
        .expect(.{ "PEXPIRE", "k", "86400000" }, .{ .integer = 1 }),
        .expect(.{ "PERSIST", "k" }, .{ .integer = 0 }),
        .expect(.{ "PTTL", "k" }, .{ .integer = -2 }),
        .expect(.{ "PTTL", "k" }, .{ .integer = -1 }),
        .expect(.{ "PTTL", "k" }, .{ .integer = 1500 }),
        .expect(.{ "TYPE", "k" }, .{ .raw = "+hash\r\n" }),
        .expect(.{ "TYPE", "k" }, .{ .raw = "+vectorset\r\n" }),
        .expect(.{ "RENAME", "a", "b" }, .ok),
        .expect(.{ "SCAN", "17", "MATCH", "session:*", "COUNT", "500", "TYPE", "hash" }, .{ .array = &.{
            .{ .string = "0" },
            .{ .array = &.{ .{ .string = "session:1" }, .{ .string = "session:2" } } },
        } }),
        .expect(.{ "SCAN", "0" }, .{ .array = &.{ .{ .string = "17" }, .{ .array = &.{} } } }),
    });
    defer server.stop(io);
    var t: Fixture = undefined;
    try t.init(io, &server);
    defer t.deinit();

    try testing.expectEqual(@as(u64, 2), try t.run(io, cmd.del(&.{ "a", "b" })));
    try testing.expectEqual(@as(u64, 1), try t.run(io, cmd.unlink(&.{ "a", "b" })));
    try testing.expectEqual(@as(u64, 2), try t.run(io, cmd.exists(&.{ "a", "a" })));
    try testing.expect(try t.run(io, cmd.expire("k", .fromSeconds(86400))));
    try testing.expect(!try t.run(io, cmd.persist("k")));
    try testing.expectEqual(redis.Ttl.missing, try t.run(io, cmd.ttl("k")));
    try testing.expectEqual(redis.Ttl.persistent, try t.run(io, cmd.ttl("k")));
    try testing.expectEqual(redis.Ttl{ .expires_in = .fromMilliseconds(1500) }, try t.run(io, cmd.ttl("k")));
    try testing.expectEqual(redis.KeyType.hash, try t.run(io, cmd.keyType("k")));
    try testing.expectEqual(redis.KeyType.other, try t.run(io, cmd.keyType("k")));
    try t.run(io, cmd.rename("a", "b"));
    try testing.expectEqualDeep(redis.ScanPage([]const u8){ .cursor = 0, .items = &.{ "session:1", "session:2" } }, try t.run(io, cmd.scan(.{ .cursor = 17, .match = "session:*", .count = 500, .type = .hash })));
    try testing.expectEqualDeep(redis.ScanPage([]const u8){ .cursor = 17, .items = &.{} }, try t.run(io, cmd.scan(.{})));
    try server.finish(io);
}

test "one PING runs twice, and the server answers it" {
    try within5s(testing.io, pingTwice, .{testing.io});
}

fn pingTwice(io: Io) !void {
    // The server answers PING itself, and journals it.
    var server: FakeServer = try .start(testing.allocator, io, &.{});
    defer server.stop(io);
    var t: Fixture = undefined;
    try t.init(io, &server);
    defer t.deinit();
    const ping = cmd.ping();
    try t.run(io, ping);
    try t.run(io, ping);
    try testing.expectEqual(@as(usize, 2), server.count(io, "PING"));
    try testing.expectEqual(@as(usize, 1), (try server.entry(io, 1)).args.len);
    try server.finish(io);
}

test "no keys, a time to live under 1 ms or longer than the client counts, and a TYPE that names no type are InvalidArgument, and nothing goes out" {
    try within5s(testing.io, refused, .{testing.io});
}

fn refused(io: Io) !void {
    var server: FakeServer = try .start(testing.allocator, io, &.{});
    defer server.stop(io);
    var t: Fixture = undefined;
    try t.init(io, &server);
    defer t.deinit();

    try testing.expectError(error.InvalidArgument, t.run(io, cmd.del(&.{})));
    try testing.expectEqualStrings("redis.cmd.del: no keys: DEL takes one or more", t.d.message());
    try testing.expectError(error.InvalidArgument, t.run(io, cmd.unlink(&.{})));
    try testing.expectError(error.InvalidArgument, t.run(io, cmd.exists(&.{})));
    for ([_]Io.Duration{ .zero, .fromSeconds(-1) }) |duration| {
        try testing.expectError(error.InvalidArgument, t.run(io, cmd.expire("k", duration)));
        try testing.expectEqualStrings("redis.cmd.expire: ttl is under 1 ms: give 1 ms or more", t.d.message());
    }
    try testing.expectError(error.InvalidArgument, t.run(io, cmd.expire("k", .max)));
    try testing.expectEqualStrings("redis.cmd.expire: ttl is longer than 9223372036854775807 ms, the most the client counts", t.d.message());
    try testing.expectError(error.InvalidArgument, t.run(io, cmd.scan(.{ .type = .other })));
    try testing.expectEqualStrings("redis.cmd.scan: .type = .other names no type of a key: give string, list, set, zset, hash or stream", t.d.message());
    try testing.expectError(error.InvalidArgument, t.run(io, cmd.scan(.{ .type = .none })));
    try testing.expectEqual(@as(usize, 0), server.received(io));
}
