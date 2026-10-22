//! Tests of the hash commands of `redis.cmd` against
//! `redis.testing.FakeServer`, with the struct `Profile`: a struct and a
//! list of `redis.FieldValue` written with HSET and read back with
//! HGETALL, the other commands with their exact arguments and replies,
//! binary fields and empty values, and the checks before anything goes
//! out. Every test runs under a time limit of 5 s.

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
pub const covered = [_][]const u8{ "hset", "hsetnx", "hget", "hmget", "hgetall", "hdel", "hexists", "hlen", "hincrby", "hincrbyfloat", "hkeys", "hscan" };

const Profile = struct {
    name: []const u8,
    age: u8,
    plan: enum { free, pro },
    note: ?[]const u8 = null,
    @"created-at": i64 = 0,
};

test "hset writes a struct and a list of fields, and hgetall reads them back; an empty hash is null" {
    try within5s(testing.io, structs, .{testing.io});
}

fn structs(io: Io) !void {
    var server: FakeServer = try .start(testing.allocator, io, &.{
        .expect(.{ "HSET", "user:42", "name", "Ann", "age", "30", "plan", "pro", "created-at", "0" }, .{ .integer = 4 }),
        .expect(.{ "HSET", "k", "a", "1" }, .{ .integer = 1 }),
        .expect(.{ "HSET", "bin", "a\r\nb\x00c", "" }, .{ .integer = 1 }),
        .expect(.{ "HGETALL", "user:42" }, .map(&.{ .{ "name", "Ann" }, .{ "age", "30" }, .{ "plan", "pro" }, .{ "created-at", "5" } })),
        .expect(.{ "HGETALL", "user:43" }, .{ .pairs = &.{} }),
        .expect(.{ "HGETALL", "k" }, .map(&.{ .{ "a", "1" }, .{ "b", "2" } })),
        .expect(.{ "HGET", "bin", "a\r\nb\x00c" }, .{ .string = "" }),
    });
    defer server.stop(io);
    var t: Fixture = undefined;
    try t.init(io, &server);
    defer t.deinit();

    try t.run(io, cmd.hset("user:42", Profile{ .name = "Ann", .age = 30, .plan = .pro }));
    try t.run(io, cmd.hset("k", &.{.{ .field = "a", .value = "1" }}));
    // A binary field with an empty value: written, not left out.
    try t.run(io, cmd.hset("bin", &.{.{ .field = "a\r\nb\x00c", .value = "" }}));
    try testing.expectEqualDeep(@as(?Profile, .{ .name = "Ann", .age = 30, .plan = .pro, .note = null, .@"created-at" = 5 }), try t.run(io, cmd.hgetall(Profile, "user:42")));
    try testing.expectEqualDeep(@as(?Profile, null), try t.run(io, cmd.hgetall(Profile, "user:43")));
    const fields: []const redis.FieldValue = &.{ .{ .field = "a", .value = "1" }, .{ .field = "b", .value = "2" } };
    try testing.expectEqualDeep(@as(?[]const redis.FieldValue, fields), try t.run(io, cmd.hgetall([]const redis.FieldValue, "k")));
    try testing.expectEqualDeep(@as(?[]const u8, ""), try t.run(io, cmd.hget([]const u8, "bin", "a\r\nb\x00c")));
    try testing.expectEqualStrings("a\r\nb\x00c", (try server.entry(io, 2)).args[2]);
    try server.finish(io);
}

test "the other hash commands send their arguments and read their replies; HINCRBYFLOAT answers with a string, HSCAN with flat pairs" {
    try within5s(testing.io, commands, .{testing.io});
}

fn commands(io: Io) !void {
    var server: FakeServer = try .start(testing.allocator, io, &.{
        .expect(.{ "HSETNX", "k", "f", "v" }, .{ .integer = 1 }),
        .expect(.{ "HSETNX", "k", "f", "3" }, .{ .integer = 0 }),
        .expect(.{ "HGET", "k", "age" }, .{ .string = "30" }),
        .expect(.{ "HGET", "k", "x" }, .nil),
        .expect(.{ "HMGET", "k", "name", "x" }, .{ .array = &.{ .{ .string = "Ann" }, .nil } }),
        .expect(.{ "HDEL", "k", "a", "b" }, .{ .integer = 1 }),
        .expect(.{ "HEXISTS", "k", "a" }, .{ .integer = 0 }),
        .expect(.{ "HLEN", "k" }, .{ .integer = 2 }),
        .expect(.{ "HINCRBY", "k", "age", "-1" }, .{ .integer = 29 }),
        .expect(.{ "HINCRBYFLOAT", "k", "f", "1.5" }, .{ .string = "2.5" }),
        .expect(.{ "HKEYS", "k" }, .{ .array = &.{ .{ .string = "a" }, .{ .string = "b" } } }),
        .expect(.{ "HSCAN", "k", "0", "MATCH", "a*", "COUNT", "10" }, .{ .array = &.{
            .{ .string = "0" },
            .{ .array = &.{ .{ .string = "a1" }, .{ .string = "x" }, .{ .string = "a2" }, .{ .string = "y" } } },
        } }),
        .expect(.{ "HSCAN", "k", "7" }, .{ .array = &.{ .{ .string = "0" }, .{ .array = &.{} } } }),
    });
    defer server.stop(io);
    var t: Fixture = undefined;
    try t.init(io, &server);
    defer t.deinit();

    try testing.expect(try t.run(io, cmd.hsetnx("k", "f", "v")));
    try testing.expect(!try t.run(io, cmd.hsetnx("k", "f", 3)));
    try testing.expectEqual(@as(?i64, 30), try t.run(io, cmd.hget(i64, "k", "age")));
    try testing.expectEqual(@as(?i64, null), try t.run(io, cmd.hget(i64, "k", "x")));
    try testing.expectEqualDeep(@as([]const ?[]const u8, &.{ "Ann", null }), try t.run(io, cmd.hmget([]const u8, "k", &.{ "name", "x" })));
    try testing.expectEqual(@as(u64, 1), try t.run(io, cmd.hdel("k", &.{ "a", "b" })));
    try testing.expect(!try t.run(io, cmd.hexists("k", "a")));
    try testing.expectEqual(@as(u64, 2), try t.run(io, cmd.hlen("k")));
    try testing.expectEqual(@as(i64, 29), try t.run(io, cmd.hincrby("k", "age", -1)));
    try testing.expectEqual(@as(f64, 2.5), try t.run(io, cmd.hincrbyfloat("k", "f", 1.5)));
    try testing.expectEqualDeep(@as([]const []const u8, &.{ "a", "b" }), try t.run(io, cmd.hkeys("k")));
    const page: redis.ScanPage(redis.FieldValue) = .{ .cursor = 0, .items = &.{ .{ .field = "a1", .value = "x" }, .{ .field = "a2", .value = "y" } } };
    try testing.expectEqualDeep(page, try t.run(io, cmd.hscan("k", .{ .match = "a*", .count = 10 })));
    try testing.expectEqualDeep(redis.ScanPage(redis.FieldValue){ .cursor = 0, .items = &.{} }, try t.run(io, cmd.hscan("k", .{ .cursor = 7 })));
    try server.finish(io);
}

test "no field to write, no fields to read or delete, and NaN are InvalidArgument, and nothing goes out" {
    try within5s(testing.io, refused, .{testing.io});
}

fn refused(io: Io) !void {
    var server: FakeServer = try .start(testing.allocator, io, &.{});
    defer server.stop(io);
    var t: Fixture = undefined;
    try t.init(io, &server);
    defer t.deinit();

    const empty: []const redis.FieldValue = &.{};
    try testing.expectError(error.InvalidArgument, t.run(io, cmd.hset("k", empty)));
    try testing.expectEqualStrings("redis.cmd.hset: no field to write: a hash takes at least one", t.d.message());
    try testing.expectError(error.InvalidArgument, t.run(io, cmd.hset("k", struct {}{})));
    const Nulls = struct { note: ?[]const u8 = null, age: ?u8 = null };
    try testing.expectError(error.InvalidArgument, t.run(io, cmd.hset("k", Nulls{})));
    try testing.expectEqualStrings("redis.cmd.hset: no field to write: a hash takes at least one", t.d.message());
    try testing.expectError(error.InvalidArgument, t.run(io, cmd.hset("k", .{ .score = std.math.nan(f64) })));
    try testing.expectEqualStrings("redis.cmd.hset: field 'score' is NaN, which a server does not take", t.d.message());
    try testing.expectError(error.InvalidArgument, t.run(io, cmd.hmget([]const u8, "k", &.{})));
    try testing.expectEqualStrings("redis.cmd.hmget: no fields: HMGET takes one or more", t.d.message());
    try testing.expectError(error.InvalidArgument, t.run(io, cmd.hdel("k", &.{})));
    try testing.expectEqualStrings("redis.cmd.hdel: no fields: HDEL takes one or more", t.d.message());
    try testing.expectError(error.InvalidArgument, t.run(io, cmd.hsetnx("k", "f", std.math.nan(f64))));
    try testing.expectEqualStrings("redis.cmd.hsetnx: value is NaN, which a server does not take", t.d.message());
    try testing.expectError(error.InvalidArgument, t.run(io, cmd.hincrbyfloat("k", "f", std.math.nan(f64))));
    try testing.expectEqualStrings("redis.cmd.hincrbyfloat: by is NaN, which a server does not take", t.d.message());
    try testing.expectEqual(@as(usize, 0), server.received(io));
}
