//! Tests of `redis.Client.iterate` and `redis.Iterator`: the items of a
//! scan, page by page, against `redis.testing.FakeServer` over loopback.
//! `iterate` does no I/O; a page whose cursor is not 0 leads to the next,
//! an empty one too, and the cursor 0 ends the walk; a page that failed
//! leaves the cursor where it was, so that the next `next` asks for the
//! same page; each scan gives its own items; `deinit` frees the page.
//! Every test runs under a time limit of 5 s.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const redis = @import("../root.zig");
const cmd = redis.cmd;
const Client = redis.Client;
const Diagnostics = redis.Diagnostics;
const FakeServer = redis.testing.FakeServer;
const within5s = @import("time_limit.zig").within5s;

/// A client of `server`, connected.
fn connected(io: Io, client: *Client, server: *const FakeServer) !void {
    client.* = try .init(testing.allocator, io, .{ .url = server.url() });
    errdefer client.deinit();
    try client.connect(io, .root, null);
}

/// The next item of `it`, which must be there.
fn expectNext(comptime T: type, io: Io, it: *redis.Iterator(T), expected: T) !void {
    try testing.expectEqualDeep(@as(?T, expected), try it.next(io, .of(.root)));
}

test "iterate does no I/O; next gives the items of each page until the cursor 0, then null, each page on a connection of the pool for one exchange" {
    try within5s(testing.io, pages, .{testing.io});
}

fn pages(io: Io) !void {
    var server: FakeServer = try .start(testing.allocator, io, &.{
        .expect(.{ "SCAN", "0", "MATCH", "s:*" }, .{ .array = &.{ .{ .string = "17" }, .{ .array = &.{ .{ .string = "a" }, .{ .string = "b" } } } } }),
        .expect(.{ "SCAN", "17", "MATCH", "s:*" }, .{ .array = &.{ .{ .string = "0" }, .{ .array = &.{.{ .string = "c" }} } } }),
    });
    defer server.stop(io);
    var client: Client = undefined;
    try connected(io, &client, &server);
    defer client.deinit();

    var keys = client.iterate(cmd.scan(.{ .match = "s:*" }), .{ .allocator = testing.allocator });
    defer keys.deinit();
    try testing.expectEqual(@as(usize, 0), server.received(io));
    for ([_][]const u8{ "a", "b", "c" }) |key| try expectNext([]const u8, io, &keys, key);
    try testing.expectEqualDeep(@as(?[]const u8, null), try keys.next(io, .of(.root)));
    // The walk is over: nothing more goes out.
    try testing.expectEqualDeep(@as(?[]const u8, null), try keys.next(io, .of(.root)));
    try testing.expectEqual(@as(usize, 2), server.received(io));
    try testing.expectEqual(@as(usize, 1), client.stats().idle);
    try server.finish(io);
}

test "an empty page whose cursor is not 0 leads to the next page" {
    try within5s(testing.io, emptyPage, .{testing.io});
}

fn emptyPage(io: Io) !void {
    var server: FakeServer = try .start(testing.allocator, io, &.{
        .expect(.{ "SCAN", "0" }, .{ .array = &.{ .{ .string = "5" }, .{ .array = &.{} } } }),
        .expect(.{ "SCAN", "5" }, .{ .array = &.{ .{ .string = "0" }, .{ .array = &.{.{ .string = "x" }} } } }),
    });
    defer server.stop(io);
    var client: Client = undefined;
    try connected(io, &client, &server);
    defer client.deinit();

    var keys = client.iterate(cmd.scan(.{}), .{ .allocator = testing.allocator });
    defer keys.deinit();
    try expectNext([]const u8, io, &keys, "x");
    try testing.expectEqualDeep(@as(?[]const u8, null), try keys.next(io, .of(.root)));
    try server.finish(io);
}

test "a page that failed leaves the cursor where it was: the next next asks for the same page again" {
    try within5s(testing.io, failedPage, .{testing.io});
}

fn failedPage(io: Io) !void {
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;
    var server: FakeServer = try .start(testing.allocator, io, &.{
        .expect(.{ "SCAN", "0" }, .{ .array = &.{ .{ .string = "17" }, .{ .array = &.{.{ .string = "a" }} } } }),
        .expect(.{ "SCAN", "17" }, .close_connection),
        .expect(.{ "SCAN", "17" }, .{ .array = &.{ .{ .string = "0" }, .{ .array = &.{.{ .string = "b" }} } } }),
    });
    defer server.stop(io);
    var client: Client = undefined;
    try connected(io, &client, &server);
    defer client.deinit();

    var d: Diagnostics = .{};
    var keys = client.iterate(cmd.scan(.{}), .{ .allocator = testing.allocator, .diagnostics = &d });
    defer keys.deinit();
    try expectNext([]const u8, io, &keys, "a");
    try testing.expectError(error.ConnectionLost, keys.next(io, .of(.root)));
    try testing.expect(std.mem.endsWith(u8, d.message(), " closed the connection"));
    try expectNext([]const u8, io, &keys, "b");
    try testing.expectEqualStrings("", d.message());
    try testing.expectEqualDeep(@as(?[]const u8, null), try keys.next(io, .of(.root)));
    try testing.expectEqual(@as(usize, 3), server.count(io, "SCAN"));
    try server.finish(io);
}

test "hscan gives fields with their values, zscan members with their scores, sscan members" {
    try within5s(testing.io, keyed, .{testing.io});
}

fn keyed(io: Io) !void {
    var server: FakeServer = try .start(testing.allocator, io, &.{
        .expect(.{ "HSCAN", "h", "0" }, .{ .array = &.{ .{ .string = "0" }, .{ .array = &.{ .{ .string = "f" }, .{ .string = "v" }, .{ .string = "g" }, .{ .string = "w" } } } } }),
        .expect(.{ "ZSCAN", "z", "0", "COUNT", "10" }, .{ .array = &.{ .{ .string = "0" }, .{ .array = &.{ .{ .string = "ann" }, .{ .string = "12.5" } } } } }),
        .expect(.{ "SSCAN", "s", "0", "MATCH", "a*" }, .{ .array = &.{ .{ .string = "0" }, .{ .array = &.{.{ .string = "a" }} } } }),
    });
    defer server.stop(io);
    var client: Client = undefined;
    try connected(io, &client, &server);
    defer client.deinit();

    var fields = client.iterate(cmd.hscan("h", .{}), .{ .allocator = testing.allocator });
    defer fields.deinit();
    try expectNext(redis.FieldValue, io, &fields, .{ .field = "f", .value = "v" });
    try expectNext(redis.FieldValue, io, &fields, .{ .field = "g", .value = "w" });
    try testing.expectEqualDeep(@as(?redis.FieldValue, null), try fields.next(io, .of(.root)));
    var scores = client.iterate(cmd.zscan("z", .{ .count = 10 }), .{ .allocator = testing.allocator });
    defer scores.deinit();
    try expectNext(redis.Scored([]const u8), io, &scores, .{ .member = "ann", .score = 12.5 });
    try testing.expectEqualDeep(@as(?redis.Scored([]const u8), null), try scores.next(io, .of(.root)));
    var members = client.iterate(cmd.sscan("s", .{ .match = "a*" }), .{ .allocator = testing.allocator });
    defer members.deinit();
    try expectNext([]const u8, io, &members, "a");
    try testing.expectEqualDeep(@as(?[]const u8, null), try members.next(io, .of(.root)));
    try server.finish(io);
}

test "deinit frees a page read halfway; a scan that breaks a rule is InvalidArgument at next, and nothing goes out" {
    try within5s(testing.io, halfway, .{testing.io});
}

fn halfway(io: Io) !void {
    var server: FakeServer = try .start(testing.allocator, io, &.{
        .expect(.{ "SCAN", "0" }, .{ .array = &.{ .{ .string = "9" }, .{ .array = &.{ .{ .string = "a" }, .{ .string = "b" } } } } }),
    });
    defer server.stop(io);
    var client: Client = undefined;
    try connected(io, &client, &server);
    defer client.deinit();

    var keys = client.iterate(cmd.scan(.{}), .{ .allocator = testing.allocator });
    try expectNext([]const u8, io, &keys, "a");
    keys.deinit();
    var d: Diagnostics = .{};
    var wrong = client.iterate(cmd.scan(.{ .type = .other }), .{ .allocator = testing.allocator, .diagnostics = &d });
    defer wrong.deinit();
    try testing.expectError(error.InvalidArgument, wrong.next(io, .of(.root)));
    try testing.expectEqualStrings("redis.cmd.scan: .type = .other names no type of a key: give string, list, set, zset, hash or stream", d.message());
    try testing.expectEqual(@as(usize, 1), server.received(io));
    try server.finish(io);
}
