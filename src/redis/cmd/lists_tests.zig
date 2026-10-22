//! Tests of the list commands of `redis.cmd` against
//! `redis.testing.FakeServer`: each with its exact arguments and its reply
//! read from the RESP3 form a server gives it; the blocking ones, BLPOP,
//! BRPOP and BLMOVE, with their timeouts in seconds taken from the
//! deadline as the design's §6 says, and DeadlineExceeded that names what
//! waits less; the checks before anything goes out. Every test runs under
//! a time limit of 5 s.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const redis = @import("../root.zig");
const cmd = redis.cmd;
const FakeServer = redis.testing.FakeServer;
const fixture = @import("fixture.zig");
const Fixture = fixture.Fixture;
const within = fixture.within;
const within5s = @import("../tests/time_limit.zig").within5s;

/// The functions of `redis.cmd` that this file tests, for the check that
/// every function of the catalog has a test.
pub const covered = [_][]const u8{ "lpush", "rpush", "lpop", "rpop", "llen", "lrange", "ltrim", "lrem", "lindex", "lmove", "blpop", "brpop", "blmove" };

test "the list commands send their arguments, values as a slice of strings or a tuple, and read their replies" {
    try within5s(testing.io, lists, .{testing.io});
}

fn lists(io: Io) !void {
    var server: FakeServer = try .start(testing.allocator, io, &.{
        .expect(.{ "RPUSH", "orders:new", "o1" }, .{ .integer = 1 }),
        .expect(.{ "LPUSH", "k", "a", "42", "1.5" }, .{ .integer = 3 }),
        .expect(.{ "RPUSH", "k", "x", "y" }, .{ .integer = 5 }),
        .expect(.{ "LPOP", "k" }, .nil),
        .expect(.{ "RPOP", "k" }, .{ .string = "a" }),
        .expect(.{ "LLEN", "k" }, .{ .integer = 2 }),
        .expect(.{ "LRANGE", "k", "0", "-1" }, .{ .array = &.{ .{ .string = "a" }, .{ .string = "b" } } }),
        .expect(.{ "LTRIM", "k", "0", "99" }, .ok),
        .expect(.{ "LREM", "k", "-2", "x" }, .{ .integer = 1 }),
        .expect(.{ "LINDEX", "k", "-1" }, .{ .string = "42" }),
        .expect(.{ "LINDEX", "k", "7" }, .nil),
        .expect(.{ "LMOVE", "src", "dst", "LEFT", "RIGHT" }, .{ .string = "job" }),
        .expect(.{ "LMOVE", "src", "dst", "RIGHT", "LEFT" }, .nil),
    });
    defer server.stop(io);
    var t: Fixture = undefined;
    try t.init(io, &server);
    defer t.deinit();

    try testing.expectEqual(@as(u64, 1), try t.run(io, cmd.rpush("orders:new", &.{"o1"})));
    try testing.expectEqual(@as(u64, 3), try t.run(io, cmd.lpush("k", .{ "a", 42, 1.5 })));
    var built: [2][]const u8 = .{ "x", "y" };
    const values: []const []const u8 = &built;
    try testing.expectEqual(@as(u64, 5), try t.run(io, cmd.rpush("k", values)));
    try testing.expectEqualDeep(@as(?[]const u8, null), try t.run(io, cmd.lpop([]const u8, "k")));
    try testing.expectEqualDeep(@as(?[]const u8, "a"), try t.run(io, cmd.rpop([]const u8, "k")));
    try testing.expectEqual(@as(u64, 2), try t.run(io, cmd.llen("k")));
    try testing.expectEqualDeep(@as([]const []const u8, &.{ "a", "b" }), try t.run(io, cmd.lrange([]const u8, "k", 0, -1)));
    try t.run(io, cmd.ltrim("k", 0, 99));
    try testing.expectEqual(@as(u64, 1), try t.run(io, cmd.lrem("k", -2, "x")));
    try testing.expectEqual(@as(?i64, 42), try t.run(io, cmd.lindex(i64, "k", -1)));
    try testing.expectEqual(@as(?i64, null), try t.run(io, cmd.lindex(i64, "k", 7)));
    try testing.expectEqualDeep(@as(?[]const u8, "job"), try t.run(io, cmd.lmove([]const u8, "src", "dst", .left, .right)));
    try testing.expectEqualDeep(@as(?[]const u8, null), try t.run(io, cmd.lmove([]const u8, "src", "dst", .right, .left)));
    try server.finish(io);
}

/// The timeout that the command number `i` of the journal sent, its last
/// argument, in seconds with a fraction: in milliseconds.
fn sent(io: Io, server: *FakeServer, i: usize) !u64 {
    const args = (try server.entry(io, i)).args;
    const text = args[args.len - 1];
    const dot = std.mem.findScalar(u8, text, '.') orelse text.len;
    var ms = std.math.mul(u64, 1000, try std.fmt.parseInt(u64, text[0..dot], 10)) catch return error.TestUnexpectedResult;
    if (dot < text.len) {
        const fraction = text[dot + 1 ..];
        if (fraction.len == 0 or fraction.len > 3) return error.TestUnexpectedResult;
        var scale: u64 = 100;
        for (fraction) |c| {
            if (!std.ascii.isDigit(c)) return error.TestUnexpectedResult;
            ms += (c - '0') * scale;
            scale /= 10;
        }
    }
    return ms;
}

fn expectSent(io: Io, server: *FakeServer, i: usize, args: []const []const u8) !void {
    const got = (try server.entry(io, i)).args;
    try testing.expectEqual(args.len + 1, got.len);
    for (args, got[0..args.len]) |want, arg| try testing.expectEqualStrings(want, arg);
}

test "blpop, brpop and blmove send a timeout in seconds that the deadline leaves beyond 150 ms, or their own, and read a key and its value, or null" {
    try within5s(testing.io, blocking, .{testing.io});
}

fn blocking(io: Io) !void {
    var replies: fixture.Replies = .{ .replies = &.{
        .{ .array = &.{ .{ .string = "q" }, .{ .string = "job" } } },
        .nil,
        .{ .array = &.{ .{ .string = "r" }, .{ .string = "x" } } },
        .{ .string = "job" },
        .nil,
    } };
    var server: FakeServer = try .startWith(testing.allocator, io, .{ .handler = .init(&replies) });
    defer server.stop(io);
    var t: Fixture = undefined;
    try t.init(io, &server);
    defer t.deinit();

    const popped: redis.Popped([]const u8) = .{ .key = "q", .value = "job" };
    try testing.expectEqualDeep(@as(?redis.Popped([]const u8), popped), try t.runIn(io, within(io, .fromSeconds(1)), cmd.blpop([]const u8, &.{"q"}, .{ .at_most = .fromSeconds(30) })));
    try testing.expectEqualDeep(@as(?redis.Popped([]const u8), null), try t.runIn(io, within(io, .fromSeconds(1)), cmd.blpop([]const u8, &.{"q"}, .forever)));
    const right: redis.Popped([]const u8) = .{ .key = "r", .value = "x" };
    try testing.expectEqualDeep(@as(?redis.Popped([]const u8), right), try t.runIn(io, within(io, .fromSeconds(1)), cmd.brpop([]const u8, &.{ "q", "r" }, .{ .at_most = .fromMilliseconds(200) })));
    // Without a deadline: its own timeout, 0 for forever.
    try testing.expectEqualDeep(@as(?[]const u8, "job"), try t.run(io, cmd.blmove([]const u8, "src", "dst", .left, .right, .forever)));
    try testing.expectEqualDeep(@as(?[]const u8, null), try t.runIn(io, within(io, .fromSeconds(1)), cmd.blmove([]const u8, "src", "dst", .right, .left, .{ .at_most = .fromSeconds(30) })));

    try expectSent(io, &server, 0, &.{ "BLPOP", "q" });
    try expectSent(io, &server, 1, &.{ "BLPOP", "q" });
    for ([_]usize{ 0, 1, 4 }) |i| {
        const timeout_ms = try sent(io, &server, i);
        try testing.expect(timeout_ms >= 800 and timeout_ms <= 850);
    }
    try expectSent(io, &server, 2, &.{ "BRPOP", "q", "r" });
    try testing.expectEqualStrings("0.2", (try server.entry(io, 2)).args[3]);
    try expectSent(io, &server, 3, &.{ "BLMOVE", "src", "dst", "LEFT", "RIGHT" });
    try testing.expectEqualStrings("0", (try server.entry(io, 3)).args[5]);
    try expectSent(io, &server, 4, &.{ "BLMOVE", "src", "dst", "RIGHT", "LEFT" });
    try server.finish(io);
}

test "a deadline too short for a blocking command is DeadlineExceeded that names what waits less; empty lists, a timeout under 1 ms and NaN are InvalidArgument; nothing goes out" {
    try within5s(testing.io, refused, .{testing.io});
}

fn refused(io: Io) !void {
    var server: FakeServer = try .start(testing.allocator, io, &.{});
    defer server.stop(io);
    var t: Fixture = undefined;
    try t.init(io, &server);
    defer t.deinit();

    try testing.expectError(error.DeadlineExceeded, t.runIn(io, within(io, .fromMilliseconds(100)), cmd.blpop([]const u8, &.{"q"}, .{ .at_most = .fromSeconds(30) })));
    try testing.expect(std.mem.endsWith(u8, t.d.message(), "for a shorter wait, use redis.cmd.lpop"));
    try testing.expectError(error.DeadlineExceeded, t.runIn(io, within(io, .fromMilliseconds(100)), cmd.brpop([]const u8, &.{"q"}, .forever)));
    try testing.expect(std.mem.endsWith(u8, t.d.message(), "for a shorter wait, use redis.cmd.rpop"));
    try testing.expectError(error.DeadlineExceeded, t.runIn(io, within(io, .fromMilliseconds(100)), cmd.blmove([]const u8, "src", "dst", .left, .right, .forever)));
    try testing.expect(std.mem.endsWith(u8, t.d.message(), "for a shorter wait, use redis.cmd.lmove"));

    try testing.expectError(error.InvalidArgument, t.run(io, cmd.blpop([]const u8, &.{}, .forever)));
    try testing.expectEqualStrings("redis.cmd.blpop: no keys: BLPOP takes one or more", t.d.message());
    try testing.expectError(error.InvalidArgument, t.run(io, cmd.brpop([]const u8, &.{"q"}, .{ .at_most = .fromMicroseconds(500) })));
    try testing.expectEqualStrings("redis.cmd.brpop: the timeout .at_most is under 1 ms, which a server takes as forever: give 1 ms or more, or .forever", t.d.message());
    try testing.expectError(error.InvalidArgument, t.run(io, cmd.blmove([]const u8, "src", "dst", .left, .right, .{ .at_most = .max })));
    try testing.expectEqualStrings("redis.cmd.blmove: the timeout .at_most is longer than 9223372036854775807 ms, the most the client counts", t.d.message());
    try testing.expectError(error.InvalidArgument, t.run(io, cmd.lpush("k", .{})));
    try testing.expectEqualStrings("redis.cmd.lpush: no values: LPUSH takes one or more", t.d.message());
    try testing.expectError(error.InvalidArgument, t.run(io, cmd.rpush("k", &.{})));
    try testing.expectEqualStrings("redis.cmd.rpush: no values: RPUSH takes one or more", t.d.message());
    try testing.expectError(error.InvalidArgument, t.run(io, cmd.lpush("k", .{ "a", std.math.nan(f64) })));
    try testing.expectEqualStrings("redis.cmd.lpush: values[1] is NaN, which a server does not take", t.d.message());
    try testing.expectError(error.InvalidArgument, t.run(io, cmd.lrem("k", 0, std.math.nan(f64))));
    try testing.expectEqualStrings("redis.cmd.lrem: value is NaN, which a server does not take", t.d.message());
    try testing.expectEqual(@as(usize, 0), server.received(io));
}
