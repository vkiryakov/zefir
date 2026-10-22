//! The kinds of RESP3 against the servers that REDIS_IMAGE names, through
//! `DEBUG PROTOCOL` of redis-plain, which answers with a reply of the kind
//! it is given, and through the doubles of ZSCORE and of Lua: an attribute
//! is skipped and the reply after it read; a big number, a verbatim string
//! without its `txt:`, a map, a set, a double, the booleans and null read
//! into their Zig types and into `redis.Value`; the doubles inf, -inf and
//! nan read as such; and a push, which a connection of the pool skips, is
//! no reply of a call.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const redis = @import("redis");
const cmd = redis.cmd;
const Value = redis.Value;
const e2e = @import("root.zig");
const within = e2e.within;

/// `DEBUG PROTOCOL <kind>`: the reply of that kind, read into `T`.
fn debugProtocol(s: *e2e.Session, comptime T: type, kind: []const u8) !T {
    return s.run(cmd.raw(T, .{ "DEBUG", "PROTOCOL", kind }));
}

test "an attribute before a reply is skipped, and the reply after it is the reply" {
    try e2e.onZio(attribute);
}

fn attribute(io: Io) !void {
    var s: e2e.Session = undefined;
    try s.open(io);
    defer s.close();
    const text = "Some real reply following the attribute";
    try testing.expectEqualDeep(@as(?[]const u8, text), try debugProtocol(&s, ?[]const u8, "attrib"));
    try testing.expectEqualDeep(Value{ .string = text }, try debugProtocol(&s, Value, "attrib"));
}

test "a big number, a verbatim string, a map, a set, a double, the booleans and null read into their Zig types and into redis.Value" {
    try e2e.onZio(kinds);
}

fn kinds(io: Io) !void {
    var s: e2e.Session = undefined;
    try s.open(io);
    defer s.close();

    const big = "1234567999999999999999999999999999999";
    try testing.expectEqualStrings(big, try debugProtocol(&s, []const u8, "bignum"));
    try testing.expectEqualDeep(Value{ .big_number = big }, try debugProtocol(&s, Value, "bignum"));

    // The text without its format, `txt:`.
    const verbatim = "This is a verbatim\nstring";
    try testing.expectEqualStrings(verbatim, try debugProtocol(&s, []const u8, "verbatim"));
    try testing.expectEqualDeep(Value{ .string = verbatim }, try debugProtocol(&s, Value, "verbatim"));

    // The map of DEBUG PROTOCOL has numbers for keys: a Value. A map with
    // names for keys, from Lua, reads into a struct.
    try testing.expectEqualDeep(Value{ .map = &.{
        .{ .key = .{ .integer = 0 }, .value = .{ .boolean = false } },
        .{ .key = .{ .integer = 1 }, .value = .{ .boolean = true } },
        .{ .key = .{ .integer = 2 }, .value = .{ .boolean = false } },
    } }, try debugProtocol(&s, Value, "map"));
    const Named = struct { a: i64, b: []const u8 };
    try testing.expectEqualDeep(@as(?Named, .{ .a = 1, .b = "two" }), try s.run(cmd.eval(?Named, "redis.setresp(3) return {map = {a = 1, b = 'two'}}", &.{}, .{})));

    try testing.expectEqualDeep(@as([]const i64, &.{ 0, 1, 2 }), try debugProtocol(&s, []const i64, "set"));
    try testing.expectEqualDeep(Value{ .set = &.{ .{ .integer = 0 }, .{ .integer = 1 }, .{ .integer = 2 } } }, try debugProtocol(&s, Value, "set"));

    try testing.expectEqual(@as(f64, 3.141), try debugProtocol(&s, f64, "double"));
    try testing.expectEqualDeep(Value{ .double = 3.141 }, try debugProtocol(&s, Value, "double"));

    try testing.expectEqual(true, try debugProtocol(&s, bool, "true"));
    try testing.expectEqual(false, try debugProtocol(&s, bool, "false"));
    try testing.expectEqualDeep(Value{ .boolean = true }, try debugProtocol(&s, Value, "true"));
    try testing.expectEqualDeep(Value{ .boolean = false }, try debugProtocol(&s, Value, "false"));

    try testing.expectEqual(@as(?[]const u8, null), try debugProtocol(&s, ?[]const u8, "null"));
    try testing.expectEqualDeep(@as(Value, .null), try debugProtocol(&s, Value, "null"));
}

test "the doubles inf and -inf of ZSCORE, and nan of a Lua script, read as such" {
    try e2e.onZio(doubles);
}

fn doubles(io: Io) !void {
    var s: e2e.Session = undefined;
    try s.open(io);
    defer s.close();
    const key = "e2e:resp3:scores";
    _ = try s.run(cmd.zadd(key, &.{ .{ .member = "up", .score = std.math.inf(f64) }, .{ .member = "down", .score = -std.math.inf(f64) } }, .{}));
    defer if (s.run(cmd.del(&.{key}))) |_| {} else |_| {};
    try testing.expectEqual(@as(?f64, std.math.inf(f64)), try s.run(cmd.zscore(key, "up")));
    try testing.expectEqual(@as(?f64, -std.math.inf(f64)), try s.run(cmd.zscore(key, "down")));

    const nan = "redis.setresp(3) return {double = 0/0}";
    try testing.expect(std.math.isNan(try s.run(cmd.eval(f64, nan, &.{}, .{}))));
    switch (try s.run(cmd.eval(Value, nan, &.{}, .{}))) {
        .double => |d| try testing.expect(std.math.isNan(d)),
        else => |other| {
            std.debug.print("a Lua NaN read as {any}\n", .{other});
            return error.TestUnexpectedResult;
        },
    }
}

test "a push on a connection of the pool is skipped: the reply of the call is its own, and the connection serves the next call" {
    try e2e.onZio(push);
}

fn push(io: Io) !void {
    var s: e2e.Session = undefined;
    try s.open(io);
    defer s.close();
    // A Conn keeps both calls on one connection: the push comes around
    // the reply of DEBUG PROTOCOL push, before it or after it.
    var conn = try s.client.acquire(io, within(io, .fromSeconds(10)));
    defer conn.release(io);
    var d: redis.Diagnostics = .{};
    const reply = try conn.run(io, within(io, .fromSeconds(10)), cmd.raw(?[]const u8, .{ "DEBUG", "PROTOCOL", "push" }), .{ .allocator = s.arena.allocator(), .diagnostics = &d });
    try testing.expectEqualDeep(@as(?[]const u8, "Some real reply following the push reply"), reply);
    try testing.expectEqualStrings("PONG", try conn.run(io, within(io, .fromSeconds(10)), cmd.raw([]const u8, .{"PING"}), .{ .allocator = s.arena.allocator(), .diagnostics = &d }));
    try testing.expectEqual(@as(?i64, 1), try conn.run(io, within(io, .fromSeconds(10)), cmd.raw(?i64, .{ "ECHO", "1" }), .{ .diagnostics = &d }));
    try testing.expectEqual(@as(usize, 1), s.client.stats().connections);
}
