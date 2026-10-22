//! The limits of a reply against the servers that REDIS_IMAGE names: a
//! table of Lua nested 8,000 deep is ReplyTooLarge, past the 64 levels the
//! client reads, and a value of 2 MiB is ReplyTooLarge for a client whose
//! max_reply_bytes is 1 MiB; each closes only its own connection, and the
//! next call passes. A value of 32 MiB goes to the server and comes back
//! byte for byte.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const redis = @import("redis");
const cmd = redis.cmd;
const e2e = @import("root.zig");
const within = e2e.within;

/// The connection closed, the pool not cleared: the error was the reply's.
fn expectClosedOnly(client: *redis.Client) !void {
    const stats = client.stats();
    try testing.expectEqual(@as(usize, 0), stats.connections);
    try testing.expectEqual(@as(u64, 0), stats.clears);
}

test "a table of Lua nested 8,000 deep is ReplyTooLarge: its connection closes, and the next call passes" {
    try e2e.onZio(deepTable);
}

fn deepTable(io: Io) !void {
    var s: e2e.Session = undefined;
    try s.open(io);
    defer s.close();
    const script = "local t = {1} for i = 1, 8000 do t = {t} end return t";
    var d: redis.Diagnostics = .{};
    try testing.expectError(error.ReplyTooLarge, s.client.run(io, within(io, .fromSeconds(10)), cmd.eval(redis.Value, script, &.{}, .{}), .{ .allocator = s.arena.allocator(), .diagnostics = &d }));
    try testing.expectEqualStrings("the reply is larger than max_reply_bytes (67108864) or nests deeper than 64 levels", d.message());
    try expectClosedOnly(&s.client);
    try s.run(cmd.ping());
    try testing.expectEqual(@as(usize, 1), s.client.stats().connections);
}

test "a value of 2 MiB is ReplyTooLarge for max_reply_bytes of 1 MiB: its connection closes, and the next call passes" {
    try e2e.onZio(largerThanLimit);
}

fn largerThanLimit(io: Io) !void {
    var s: e2e.Session = undefined;
    try s.open(io);
    defer s.close();
    const key = "e2e:limits:two";
    const value = try testing.allocator.alloc(u8, 2 * 1024 * 1024);
    defer testing.allocator.free(value);
    @memset(value, 'v');
    try s.run(cmd.set(key, value, .{}));
    defer if (s.run(cmd.del(&.{key}))) |_| {} else |_| {};

    var client: redis.Client = try .init(testing.allocator, io, .{ .url = "redis://127.0.0.1:16379", .max_reply_bytes = 1024 * 1024 });
    defer client.deinit();
    var d: redis.Diagnostics = .{};
    try client.connect(io, within(io, .fromSeconds(10)).ctx, &d);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.ReplyTooLarge, client.run(io, within(io, .fromSeconds(10)), cmd.get([]const u8, key), .{ .allocator = arena.allocator(), .diagnostics = &d }));
    try testing.expectEqualStrings("the reply is larger than max_reply_bytes (1048576) or nests deeper than 64 levels", d.message());
    try expectClosedOnly(&client);
    try testing.expectEqual(@as(?u64, 2 * 1024 * 1024), try client.run(io, within(io, .fromSeconds(10)), cmd.raw(?u64, .{ "STRLEN", key }), .{ .diagnostics = &d }));
    try testing.expectEqual(@as(usize, 1), client.stats().connections);
}

test "a value of 32 MiB goes to the server and comes back byte for byte" {
    try e2e.onZio(large);
}

fn large(io: Io) !void {
    var s: e2e.Session = undefined;
    try s.open(io);
    defer s.close();
    const key = "e2e:limits:large";
    const value = try testing.allocator.alloc(u8, 32 * 1024 * 1024);
    defer testing.allocator.free(value);
    for (value, 0..) |*b, i| b.* = @truncate(i *% 2654435761 >> 13);
    try s.runIn(within(io, .fromSeconds(30)), cmd.set(key, value, .{}));
    defer if (s.run(cmd.del(&.{key}))) |_| {} else |_| {};
    const back = (try s.runIn(within(io, .fromSeconds(30)), cmd.get([]const u8, key))) orelse return error.TestValueMissing;
    try testing.expectEqual(value.len, back.len);
    try testing.expect(std.mem.eql(u8, value, back));
}
