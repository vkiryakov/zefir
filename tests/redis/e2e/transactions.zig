//! Transactions of `redis.Conn` against the servers that REDIS_IMAGE
//! names: a key under WATCH that another connection changes makes the
//! transaction null; an unknown command makes the server drop it with
//! EXECABORT, and refused() names the command's own error; a user without
//! +multi gets NOPERM for MULTI, and none of the commands runs.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const core = @import("core");
const redis = @import("redis");
const cmd = redis.cmd;
const e2e = @import("root.zig");

fn within(io: Io, duration: Io.Duration) redis.OperationContext {
    return .of(core.Context.root.withDeadline(.after(Io.Clock.awake.now(io), duration)));
}

/// A client of `url`, connected.
fn connected(io: Io, client: *redis.Client, url: []const u8) !void {
    client.* = try .init(testing.allocator, io, .{ .url = url });
    errdefer client.deinit();
    var d: redis.Diagnostics = .{};
    client.connect(io, within(io, .fromSeconds(10)).ctx, &d) catch |err| {
        std.debug.print("connect: {t}: {s}\n", .{ err, d.message() });
        return err;
    };
}

test "a key under WATCH that another connection changes makes the transaction null, and none of it runs; unchanged, it runs" {
    try e2e.onZio(watchedKey);
}

fn watchedKey(io: Io) !void {
    var client: redis.Client = undefined;
    try connected(io, &client, "redis://127.0.0.1:16379");
    defer client.deinit();
    const op = within(io, .fromSeconds(10));
    const key = "e2e:tx:stock";
    try client.run(io, op, cmd.raw(void, .{ "SET", key, 10 }), .{});
    var conn = try client.acquire(io, op);
    defer conn.release(io);
    try conn.run(io, op, cmd.watch(&.{key}), .{});
    try testing.expectEqual(@as(?i64, 10), try conn.run(io, op, cmd.raw(?i64, .{ "GET", key }), .{}));
    // Another connection takes one meanwhile.
    try testing.expectEqual(@as(i64, 9), try client.run(io, op, cmd.raw(i64, .{ "DECR", key }), .{}));
    try testing.expect(try conn.transaction(io, op, .{cmd.raw(i64, .{ "DECR", key })}, .{}) == null);
    try testing.expectEqual(@as(?i64, 9), try client.run(io, op, cmd.raw(?i64, .{ "GET", key }), .{}));
    // Nobody changes it this time.
    try conn.run(io, op, cmd.watch(&.{key}), .{});
    const done = (try conn.transaction(io, op, .{ cmd.raw(i64, .{ "DECR", key }), cmd.raw(?i64, .{ "GET", key }) }, .{})) orelse
        return error.TestUnexpectedResult;
    try testing.expectEqual(@as(i64, 8), try done[0]);
    try testing.expectEqual(@as(?i64, 8), try done[1]);
}

test "an unknown command makes the server drop the transaction: EXECABORT, with the command and its own ERR in refused(), and nothing ran" {
    try e2e.onZio(unknownCommand);
}

fn unknownCommand(io: Io) !void {
    var client: redis.Client = undefined;
    try connected(io, &client, "redis://127.0.0.1:16379");
    defer client.deinit();
    const op = within(io, .fromSeconds(10));
    const key = "e2e:tx:dropped";
    _ = try client.run(io, op, cmd.raw(u64, .{ "DEL", key }), .{});
    var conn = try client.acquire(io, op);
    defer conn.release(io);
    var d: redis.Diagnostics = .{};
    try testing.expectError(error.ServerError, conn.transaction(io, op, .{ cmd.raw(void, .{ "SET", key, "x" }), cmd.raw(void, .{"FOO"}) }, .{ .diagnostics = &d }));
    try testing.expect(d.isCode("EXECABORT"));
    try testing.expectEqual(@as(?usize, 1), d.command);
    const refused = d.refused() orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("ERR", refused.code);
    try testing.expectEqual(@as(u64, 0), try conn.run(io, op, cmd.raw(u64, .{ "EXISTS", key }), .{}));
}

test "a user without +multi gets NOPERM for MULTI, and none of the commands runs" {
    try e2e.onZio(noMulti);
}

fn noMulti(io: Io) !void {
    var client: redis.Client = undefined;
    try connected(io, &client, "redis://no-multi:no-multi-pass@127.0.0.1:16380");
    defer client.deinit();
    const op = within(io, .fromSeconds(10));
    const key = "e2e:tx:no-multi";
    _ = try client.run(io, op, cmd.raw(u64, .{ "DEL", key }), .{});
    var conn = try client.acquire(io, op);
    defer conn.release(io);
    var d: redis.Diagnostics = .{};
    try testing.expectError(error.ServerError, conn.transaction(io, op, .{ cmd.raw(void, .{ "SET", key, "x" }), cmd.raw(i64, .{ "INCR", "e2e:tx:no-multi:count" }) }, .{ .diagnostics = &d }));
    try testing.expect(d.isCode("NOPERM"));
    try testing.expectEqual(@as(u64, 0), try conn.run(io, op, cmd.raw(u64, .{ "EXISTS", key, "e2e:tx:no-multi:count" }), .{}));
}
