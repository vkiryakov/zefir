//! Tests of the string and counter commands of `redis.cmd` against
//! `redis.testing.FakeServer`: the exact arguments of each, its reply read
//! from the RESP3 form a server gives it, binary values and the empty
//! string, and the checks before anything goes out — options that
//! conflict, empty lists, durations under 1 ms or longer than the client
//! counts, NaN. Every test runs under a time limit of 5 s.

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
pub const covered = [_][]const u8{ "get", "set", "setNx", "setXx", "getdel", "getex", "mget", "mset", "incr", "decr", "incrby", "decrby", "incrbyfloat" };

test "get, set, setNx, setXx, getdel and getex send their arguments and read a value, null, or the empty string, which is no null" {
    try within5s(testing.io, values, .{testing.io});
}

fn values(io: Io) !void {
    var server: FakeServer = try .start(testing.allocator, io, &.{
        .expect(.{ "GET", "session:42" }, .{ .string = "token" }),
        .expect(.{ "GET", "session:42" }, .nil),
        .expect(.{ "GET", "session:42" }, .{ .string = "" }),
        .expect(.{ "GET", "views" }, .{ .string = "42" }),
        .expect(.{ "SET", "session:42", "t", "PX", "3600000" }, .ok),
        .expect(.{ "SET", "k", "v", "KEEPTTL" }, .ok),
        .expect(.{ "SET", "n", "42" }, .ok),
        .expect(.{ "SET", "plan", "pro" }, .ok),
        .expect(.{ "SET", "k", "v", "NX", "PX", "30000" }, .ok),
        .expect(.{ "SET", "k", "v", "NX", "PX", "30000" }, .nil),
        .expect(.{ "SET", "k", "v", "XX", "KEEPTTL" }, .ok),
        .expect(.{ "SET", "k", "v", "XX" }, .nil),
        .expect(.{ "GETDEL", "k" }, .{ .string = "v" }),
        .expect(.{ "GETDEL", "k" }, .nil),
        .expect(.{ "GETEX", "k", "PX", "60000" }, .{ .string = "v" }),
        .expect(.{ "GETEX", "k", "PERSIST" }, .nil),
        .expect(.{ "GETEX", "k" }, .{ .string = "7" }),
        .expect(.{ "SET", "bin", "a\r\nb\x00c" }, .ok),
        .expect(.{ "GET", "bin" }, .{ .string = "a\r\nb\x00c" }),
    });
    defer server.stop(io);
    var t: Fixture = undefined;
    try t.init(io, &server);
    defer t.deinit();

    try testing.expectEqualDeep(@as(?[]const u8, "token"), try t.run(io, cmd.get([]const u8, "session:42")));
    try testing.expectEqualDeep(@as(?[]const u8, null), try t.run(io, cmd.get([]const u8, "session:42")));
    try testing.expectEqualDeep(@as(?[]const u8, ""), try t.run(io, cmd.get([]const u8, "session:42")));
    try testing.expectEqual(@as(?i64, 42), try t.run(io, cmd.get(i64, "views")));

    try t.run(io, cmd.set("session:42", "t", .{ .ttl = .fromSeconds(3600) }));
    try t.run(io, cmd.set("k", "v", .{ .keep_ttl = true }));
    try t.run(io, cmd.set("n", 42, .{}));
    try t.run(io, cmd.set("plan", .pro, .{}));
    try testing.expect(try t.run(io, cmd.setNx("k", "v", .{ .ttl = .fromSeconds(30) })));
    try testing.expect(!try t.run(io, cmd.setNx("k", "v", .{ .ttl = .fromSeconds(30) })));
    try testing.expect(try t.run(io, cmd.setXx("k", "v", .{ .keep_ttl = true })));
    try testing.expect(!try t.run(io, cmd.setXx("k", "v", .{})));

    try testing.expectEqualDeep(@as(?[]const u8, "v"), try t.run(io, cmd.getdel([]const u8, "k")));
    try testing.expectEqualDeep(@as(?[]const u8, null), try t.run(io, cmd.getdel([]const u8, "k")));
    try testing.expectEqualDeep(@as(?[]const u8, "v"), try t.run(io, cmd.getex([]const u8, "k", .{ .ttl = .fromSeconds(60) })));
    try testing.expectEqualDeep(@as(?[]const u8, null), try t.run(io, cmd.getex([]const u8, "k", .{ .persist = true })));
    try testing.expectEqual(@as(?u8, 7), try t.run(io, cmd.getex(u8, "k", .{})));

    // A value goes out and comes back byte for byte.
    try t.run(io, cmd.set("bin", "a\r\nb\x00c", .{}));
    try testing.expectEqualDeep(@as(?[]const u8, "a\r\nb\x00c"), try t.run(io, cmd.get([]const u8, "bin")));
    try testing.expectEqualStrings("a\r\nb\x00c", (try server.entry(io, 17)).args[2]);
    try server.finish(io);
}

test "mget, mset and the counters send their arguments and read their replies; INCRBYFLOAT answers with a string" {
    try within5s(testing.io, counters, .{testing.io});
}

fn counters(io: Io) !void {
    var server: FakeServer = try .start(testing.allocator, io, &.{
        .expect(.{ "MGET", "a", "b" }, .{ .array = &.{ .{ .string = "x" }, .nil } }),
        .expect(.{ "MSET", "a", "1", "b", "2" }, .ok),
        .expect(.{ "INCR", "k" }, .{ .integer = 3 }),
        .expect(.{ "DECR", "k" }, .{ .integer = 2 }),
        .expect(.{ "INCRBY", "k", "-9223372036854775808" }, .{ .integer = std.math.minInt(i64) }),
        .expect(.{ "DECRBY", "k", "5" }, .{ .integer = -3 }),
        .expect(.{ "INCRBYFLOAT", "k", "0.1" }, .{ .string = "0.1" }),
    });
    defer server.stop(io);
    var t: Fixture = undefined;
    try t.init(io, &server);
    defer t.deinit();

    try testing.expectEqualDeep(@as([]const ?[]const u8, &.{ "x", null }), try t.run(io, cmd.mget([]const u8, &.{ "a", "b" })));
    try t.run(io, cmd.mset(&.{ .{ .key = "a", .value = "1" }, .{ .key = "b", .value = "2" } }));
    try testing.expectEqual(@as(i64, 3), try t.run(io, cmd.incr("k")));
    try testing.expectEqual(@as(i64, 2), try t.run(io, cmd.decr("k")));
    try testing.expectEqual(@as(i64, std.math.minInt(i64)), try t.run(io, cmd.incrby("k", std.math.minInt(i64))));
    try testing.expectEqual(@as(i64, -3), try t.run(io, cmd.decrby("k", 5)));
    try testing.expectEqual(@as(f64, 0.1), try t.run(io, cmd.incrbyfloat("k", 0.1)));
    try server.finish(io);
}

test "options that conflict, empty lists, a time to live under 1 ms or longer than the client counts, and NaN are InvalidArgument, and nothing goes out" {
    try within5s(testing.io, refused, .{testing.io});
}

fn refused(io: Io) !void {
    var server: FakeServer = try .start(testing.allocator, io, &.{});
    defer server.stop(io);
    var t: Fixture = undefined;
    try t.init(io, &server);
    defer t.deinit();

    try testing.expectError(error.InvalidArgument, t.run(io, cmd.set("k", "v", .{ .ttl = .fromSeconds(1), .keep_ttl = true })));
    try testing.expectEqualStrings("redis.cmd.set: .ttl and .keep_ttl together: give the key a new time to live, or keep the one it has", t.d.message());
    try testing.expectError(error.InvalidArgument, t.run(io, cmd.setXx("k", "v", .{ .ttl = .fromSeconds(1), .keep_ttl = true })));
    try testing.expectEqualStrings("redis.cmd.setXx: .ttl and .keep_ttl together: give the key a new time to live, or keep the one it has", t.d.message());
    for ([_]Io.Duration{ .fromMicroseconds(500), .fromSeconds(-1), .zero }) |ttl| {
        try testing.expectError(error.InvalidArgument, t.run(io, cmd.set("k", "v", .{ .ttl = ttl })));
        try testing.expectEqualStrings("redis.cmd.set: .ttl is under 1 ms: give 1 ms or more", t.d.message());
    }
    try testing.expectError(error.InvalidArgument, t.run(io, cmd.set("k", "v", .{ .ttl = .max })));
    try testing.expectEqualStrings("redis.cmd.set: .ttl is longer than 9223372036854775807 ms, the most the client counts", t.d.message());
    try testing.expectError(error.InvalidArgument, t.run(io, cmd.setNx("k", "v", .{ .ttl = .max })));
    try testing.expectEqualStrings("redis.cmd.setNx: .ttl is longer than 9223372036854775807 ms, the most the client counts", t.d.message());
    try testing.expectError(error.InvalidArgument, t.run(io, cmd.getex([]const u8, "k", .{ .ttl = .fromSeconds(60), .persist = true })));
    try testing.expectEqualStrings("redis.cmd.getex: .ttl and .persist together: give the key a new time to live, or take the one it has away", t.d.message());
    try testing.expectError(error.InvalidArgument, t.run(io, cmd.getex([]const u8, "k", .{ .ttl = .fromSeconds(-1) })));
    try testing.expectEqualStrings("redis.cmd.getex: .ttl is under 1 ms: give 1 ms or more", t.d.message());
    try testing.expectError(error.InvalidArgument, t.run(io, cmd.mget([]const u8, &.{})));
    try testing.expectEqualStrings("redis.cmd.mget: no keys: MGET takes one or more", t.d.message());
    try testing.expectError(error.InvalidArgument, t.run(io, cmd.mset(&.{})));
    try testing.expectEqualStrings("redis.cmd.mset: no pairs: MSET takes one or more", t.d.message());
    try testing.expectError(error.InvalidArgument, t.run(io, cmd.incrbyfloat("k", std.math.nan(f64))));
    try testing.expectEqualStrings("redis.cmd.incrbyfloat: by is NaN, which a server does not take", t.d.message());
    try testing.expectError(error.InvalidArgument, t.run(io, cmd.set("k", std.math.nan(f64), .{})));
    try testing.expectEqualStrings("redis.cmd.set: value is NaN, which a server does not take", t.d.message());
    try testing.expectEqual(@as(usize, 0), server.received(io));
}

test "a command of the catalog holds no state: one value runs many times, and its type keeps a string literal as []const u8" {
    const set = cmd.set("k", "v", .{});
    comptime std.debug.assert(@TypeOf(set) == cmd.Set([]const u8));
    comptime std.debug.assert(@TypeOf(cmd.set("n", 42, .{})) == cmd.Set(i64));
    comptime std.debug.assert(@TypeOf(cmd.get([]const u8, "k")).Reply == ?[]const u8);
    comptime std.debug.assert(@TypeOf(cmd.mget(i64, &.{"k"})).Reply == []const ?i64);
    try within5s(testing.io, twice, .{ testing.io, set });
}

fn twice(io: Io, set: cmd.Set([]const u8)) !void {
    var server: FakeServer = try .start(testing.allocator, io, &.{
        .expect(.{ "SET", "k", "v" }, .ok),
        .expect(.{ "SET", "k", "v" }, .ok),
    });
    defer server.stop(io);
    var t: Fixture = undefined;
    try t.init(io, &server);
    defer t.deinit();
    try t.run(io, set);
    try t.run(io, set);
    try server.finish(io);
}
