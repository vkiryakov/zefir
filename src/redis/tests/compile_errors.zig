//! Calls of `redis.cmd.raw` that must not compile, one test each: reply
//! types that no reply reads into and arguments that cannot be written.
//! `zig build test-redis` compiles every test on its own and checks its
//! error message; the list of messages is in build.zig.

const redis = @import("redis");
const cmd = redis.cmd;

const Open = enum(u8) { a, _ };
const Address = struct { city: []const u8 };
const User = struct { name: []const u8, address: Address };
const Player = struct { name: []const u8, scores: []const i64 };
const Shape = union(enum) { circle: f64, square: f64 };
const Drawing = struct { shape: Shape };
const Post = struct { owner: *const User };
const Point = struct { x: i64, y: i64 };

test "reply of an optional of an optional" {
    _ = cmd.raw(??i64, .{ "GET", "k" });
}

test "reply of a non-exhaustive enum" {
    _ = cmd.raw(Open, .{ "GET", "k" });
}

test "reply with a nested struct" {
    _ = cmd.raw(User, .{ "HGETALL", "user:42" });
}

test "reply with a slice of numbers" {
    _ = cmd.raw(Player, .{ "HGETALL", "player:7" });
}

test "reply with a union" {
    _ = cmd.raw(Drawing, .{ "HGETALL", "drawing:1" });
}

test "reply with a pointer" {
    _ = cmd.raw(Post, .{ "HGETALL", "post:1" });
}

test "argument that is a struct" {
    _ = cmd.raw(i64, .{ "ZADD", "points", Point{ .x = 1, .y = 2 } });
}

test "argument that is an optional" {
    const note: ?[]const u8 = null;
    _ = cmd.raw(void, .{ "SET", note });
}

test "argument of a non-exhaustive enum" {
    _ = cmd.raw(void, .{ "SET", "k", @as(Open, .a) });
}

test "arguments that are a string" {
    _ = cmd.raw(i64, "GET");
}
