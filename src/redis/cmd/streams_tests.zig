//! Tests of the stream commands of `redis.cmd` against
//! `redis.testing.FakeServer`: each with its exact arguments and its reply
//! read from the RESP3 form a server gives it; entries read into a struct,
//! one deleted while pending with `fields == null`; XREAD and XREADGROUP of
//! one stream, none as an empty slice, with BLOCK in milliseconds taken
//! from the deadline; and the checks before anything goes out. Every test
//! runs under a time limit of 5 s.

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
pub const covered = [_][]const u8{ "xadd", "xlen", "xrange", "xrevrange", "xread", "xreadgroup", "xack", "xgroupCreate", "xpending", "xpendingRange", "xautoclaim", "xdel", "xtrim" };

const Order = struct { id: i64, total: f64 };
const Entry = redis.Entry(Order);

const first: redis.StreamId = .{ .ms = 1526919030474, .seq = 0 };
const second: redis.StreamId = .{ .ms = 1526919030474, .seq = 1 };
const order: Entry = .{ .id = first, .fields = .{ .id = 7, .total = 12.5 } };

const order_entry: FakeServer.Reply = .{ .array = &.{
    .{ .string = "1526919030474-0" },
    .{ .array = &.{ .{ .string = "id" }, .{ .string = "7" }, .{ .string = "total" }, .{ .string = "12.5" } } },
} };
const deleted_entry: FakeServer.Reply = .{ .array = &.{ .{ .string = "1526919030474-1" }, .nil } };
const orders_read: FakeServer.Reply = .{ .pairs = &.{.{ .{ .string = "orders" }, .{ .array = &.{order_entry} } }} };

test "xadd writes the fields and its options and reads the id; xlen, xrange, xrevrange, xdel and xtrim send their arguments and read their replies" {
    try within5s(testing.io, entries, .{testing.io});
}

fn entries(io: Io) !void {
    var server: FakeServer = try .start(testing.allocator, io, &.{
        .expect(.{ "XADD", "orders", "*", "id", "7", "total", "12.5" }, .{ .string = "1526919030474-0" }),
        .expect(.{ "XADD", "orders", "MAXLEN", "~", "1000", "*", "id", "7", "total", "12.5" }, .{ .string = "1526919030474-1" }),
        .expect(.{ "XADD", "orders", "NOMKSTREAM", "MAXLEN", "1000", "5-1", "note", "x" }, .{ .string = "5-1" }),
        .expect(.{ "XLEN", "orders" }, .{ .integer = 3 }),
        .expect(.{ "XRANGE", "orders", "-", "+" }, .{ .array = &.{ order_entry, deleted_entry } }),
        .expect(.{ "XRANGE", "orders", "5-1", "+", "COUNT", "10" }, .{ .array = &.{} }),
        .expect(.{ "XREVRANGE", "orders", "+", "-" }, .{ .array = &.{order_entry} }),
        .expect(.{ "XREVRANGE", "orders", "9-0", "5-1", "COUNT", "2" }, .{ .array = &.{} }),
        .expect(.{ "XDEL", "orders", "5-1", "1526919030474-0" }, .{ .integer = 2 }),
        .expect(.{ "XTRIM", "orders", "MAXLEN", "~", "1000" }, .{ .integer = 0 }),
        .expect(.{ "XTRIM", "orders", "MINID", "~", "5-1" }, .{ .integer = 1 }),
        .expect(.{ "XTRIM", "orders", "MINID", "5-1" }, .{ .integer = 1 }),
    });
    defer server.stop(io);
    var t: Fixture = undefined;
    try t.init(io, &server);
    defer t.deinit();

    try testing.expectEqual(first, try t.run(io, cmd.xadd("orders", Order{ .id = 7, .total = 12.5 }, .{})));
    try testing.expectEqual(second, try t.run(io, cmd.xadd("orders", Order{ .id = 7, .total = 12.5 }, .{ .max_len = 1000 })));
    const id: redis.StreamId = .{ .ms = 5, .seq = 1 };
    try testing.expectEqual(id, try t.run(io, cmd.xadd("orders", &.{.{ .field = "note", .value = "x" }}, .{ .id = id, .max_len = 1000, .approximate = false, .no_mkstream = true })));
    try testing.expectEqual(@as(u64, 3), try t.run(io, cmd.xlen("orders")));
    try testing.expectEqualDeep(@as([]const Entry, &.{ order, .{ .id = second, .fields = null } }), try t.run(io, cmd.xrange(Order, "orders", .{})));
    try testing.expectEqualDeep(@as([]const Entry, &.{}), try t.run(io, cmd.xrange(Order, "orders", .{ .start = id, .count = 10 })));
    try testing.expectEqualDeep(@as([]const Entry, &.{order}), try t.run(io, cmd.xrevrange(Order, "orders", .{})));
    try testing.expectEqualDeep(@as([]const Entry, &.{}), try t.run(io, cmd.xrevrange(Order, "orders", .{ .end = .{ .ms = 9, .seq = 0 }, .start = id, .count = 2 })));
    try testing.expectEqual(@as(u64, 2), try t.run(io, cmd.xdel("orders", &.{ id, first })));
    try testing.expectEqual(@as(u64, 0), try t.run(io, cmd.xtrim("orders", .{ .max_len = 1000 }, .{})));
    try testing.expectEqual(@as(u64, 1), try t.run(io, cmd.xtrim("orders", .{ .min_id = id }, .{})));
    try testing.expectEqual(@as(u64, 1), try t.run(io, cmd.xtrim("orders", .{ .min_id = id }, .{ .approximate = false })));
    try server.finish(io);
}

test "xread and xreadgroup read the entries of one stream, none as an empty slice, and an entry deleted while pending with fields null" {
    try within5s(testing.io, reads, .{testing.io});
}

fn reads(io: Io) !void {
    var server: FakeServer = try .start(testing.allocator, io, &.{
        .expect(.{ "XREAD", "COUNT", "10", "STREAMS", "orders", "1526919030474-0" }, orders_read),
        .expect(.{ "XREAD", "STREAMS", "orders", "1526919030474-1" }, .nil),
        .expect(.{ "XREADGROUP", "GROUP", "g", "c1", "STREAMS", "orders", ">" }, orders_read),
        .expect(.{ "XREADGROUP", "GROUP", "g", "c1", "COUNT", "5", "NOACK", "STREAMS", "orders", "0-0" }, .{ .pairs = &.{.{ .{ .string = "orders" }, .{ .array = &.{deleted_entry} } }} }),
        .expect(.{ "XREADGROUP", "GROUP", "g", "c2", "STREAMS", "orders", ">" }, .nil),
    });
    defer server.stop(io);
    var t: Fixture = undefined;
    try t.init(io, &server);
    defer t.deinit();

    try testing.expectEqualDeep(@as([]const Entry, &.{order}), try t.run(io, cmd.xread(Order, "orders", .{ .after = .{ .id = first }, .count = 10 })));
    try testing.expectEqualDeep(@as([]const Entry, &.{}), try t.run(io, cmd.xread(Order, "orders", .{ .after = .{ .id = second } })));
    try testing.expectEqualDeep(@as([]const Entry, &.{order}), try t.run(io, cmd.xreadgroup(Order, "orders", .{ .group = "g", .consumer = "c1" })));
    try testing.expectEqualDeep(@as([]const Entry, &.{.{ .id = second, .fields = null }}), try t.run(io, cmd.xreadgroup(Order, "orders", .{ .group = "g", .consumer = "c1", .from = .{ .id = .zero }, .count = 5, .no_ack = true })));
    try testing.expectEqualDeep(@as([]const Entry, &.{}), try t.run(io, cmd.xreadgroup(Order, "orders", .{ .group = "g", .consumer = "c2" })));
    try server.finish(io);
}

/// The BLOCK of the command number `i` of the journal, in milliseconds.
fn blockOf(io: Io, server: *FakeServer, i: usize) !u64 {
    const args = (try server.entry(io, i)).args;
    for (args[0 .. args.len - 1], 0..) |arg, at| {
        if (std.mem.eql(u8, arg, "BLOCK")) return std.fmt.parseInt(u64, args[at + 1], 10);
    }
    return error.TestNoBlock;
}

test "xread and xreadgroup with .block send BLOCK in milliseconds that the deadline leaves beyond 150 ms, or their own; without .block they do not block, under any deadline" {
    try within5s(testing.io, blocking, .{testing.io});
}

fn blocking(io: Io) !void {
    var replies: fixture.Replies = .{ .replies = &.{ orders_read, .nil, .nil, orders_read } };
    var server: FakeServer = try .startWith(testing.allocator, io, .{ .handler = .init(&replies) });
    defer server.stop(io);
    var t: Fixture = undefined;
    try t.init(io, &server);
    defer t.deinit();

    try testing.expectEqualDeep(@as([]const Entry, &.{order}), try t.runIn(io, within(io, .fromSeconds(1)), cmd.xread(Order, "orders", .{ .after = .latest, .block = .{ .at_most = .fromSeconds(5) } })));
    try testing.expectEqualDeep(@as([]const Entry, &.{}), try t.run(io, cmd.xreadgroup(Order, "orders", .{ .group = "g", .consumer = "c1", .block = .forever })));
    try testing.expectEqualDeep(@as([]const Entry, &.{}), try t.runIn(io, within(io, .fromSeconds(1)), cmd.xreadgroup(Order, "orders", .{ .group = "g", .consumer = "c1", .block = .{ .at_most = .fromMilliseconds(200) } })));
    // Without .block, nothing waits: a short deadline is no error.
    try testing.expectEqualDeep(@as([]const Entry, &.{order}), try t.runIn(io, within(io, .fromMilliseconds(100)), cmd.xread(Order, "orders", .{ .after = .{ .id = first } })));

    const block = try blockOf(io, &server, 0);
    try testing.expect(block >= 800 and block <= 850);
    try testing.expectEqualDeep(@as([]const []const u8, &.{ "XREAD", "BLOCK" }), (try server.entry(io, 0)).args[0..2]);
    try testing.expectEqualDeep(@as([]const []const u8, &.{ "STREAMS", "orders", "$" }), (try server.entry(io, 0)).args[3..]);
    try testing.expectEqualDeep(@as([]const []const u8, &.{ "XREADGROUP", "GROUP", "g", "c1", "BLOCK", "0", "STREAMS", "orders", ">" }), (try server.entry(io, 1)).args);
    try testing.expectEqual(@as(u64, 200), try blockOf(io, &server, 2));
    try testing.expectEqualDeep(@as([]const []const u8, &.{ "XREAD", "STREAMS", "orders", "1526919030474-0" }), (try server.entry(io, 3)).args);

    try testing.expectError(error.DeadlineExceeded, t.runIn(io, within(io, .fromMilliseconds(100)), cmd.xread(Order, "orders", .{ .after = .latest, .block = .forever })));
    try testing.expect(std.mem.endsWith(u8, t.d.message(), "for a shorter wait, use redis.cmd.xread without .block"));
    try testing.expectError(error.DeadlineExceeded, t.runIn(io, within(io, .fromMilliseconds(100)), cmd.xreadgroup(Order, "orders", .{ .group = "g", .consumer = "c1", .block = .forever })));
    try testing.expect(std.mem.endsWith(u8, t.d.message(), "for a shorter wait, use redis.cmd.xreadgroup without .block"));
    try testing.expectEqual(@as(usize, 4), server.received(io));
}

test "xack, xgroupCreate, xpending, xpendingRange and xautoclaim send their arguments and read their replies; BUSYGROUP is a ServerError" {
    try within5s(testing.io, groups, .{testing.io});
}

fn groups(io: Io) !void {
    var server: FakeServer = try .start(testing.allocator, io, &.{
        .expect(.{ "XACK", "orders", "g", "1526919030474-0" }, .{ .integer = 1 }),
        .expect(.{ "XGROUP", "CREATE", "orders", "g", "$", "MKSTREAM" }, .ok),
        .expect(.{ "XGROUP", "CREATE", "orders", "g", "0-0" }, .{ .err = "BUSYGROUP Consumer Group name already exists" }),
        .expect(.{ "XPENDING", "orders", "g" }, .{ .array = &.{
            .{ .integer = 2 },
            .{ .string = "1526919030474-0" },
            .{ .string = "1526919030474-1" },
            .{ .array = &.{.{ .array = &.{ .{ .string = "c1" }, .{ .string = "2" } } }} },
        } }),
        .expect(.{ "XPENDING", "orders", "g" }, .{ .array = &.{ .{ .integer = 0 }, .nil, .nil, .nil } }),
        .expect(.{ "XPENDING", "orders", "g", "IDLE", "60000", "-", "+", "10" }, .{ .array = &.{
            .{ .array = &.{ .{ .string = "1526919030474-0" }, .{ .string = "c1" }, .{ .integer = 61000 }, .{ .integer = 1 } } },
        } }),
        .expect(.{ "XPENDING", "orders", "g", "5-1", "9-0", "10", "c1" }, .{ .array = &.{} }),
        .expect(.{ "XAUTOCLAIM", "orders", "g", "c2", "60000", "0-0" }, .{ .array = &.{
            .{ .string = "0-0" },
            .{ .array = &.{order_entry} },
            .{ .array = &.{.{ .string = "1526919030474-1" }} },
        } }),
        .expect(.{ "XAUTOCLAIM", "orders", "g", "c2", "100", "5-1", "COUNT", "25" }, .{ .array = &.{ .{ .string = "0-0" }, .{ .array = &.{} }, .{ .array = &.{} } } }),
    });
    defer server.stop(io);
    var t: Fixture = undefined;
    try t.init(io, &server);
    defer t.deinit();

    try testing.expectEqual(@as(u64, 1), try t.run(io, cmd.xack("orders", "g", &.{first})));
    try t.run(io, cmd.xgroupCreate("orders", "g", .{ .mkstream = true }));
    try testing.expectError(error.ServerError, t.run(io, cmd.xgroupCreate("orders", "g", .{ .start = .{ .id = .zero } })));
    try testing.expect(t.d.isCode("BUSYGROUP"));
    const summary: redis.PendingSummary = .{ .count = 2, .first = first, .last = second, .consumers = &.{.{ .name = "c1", .count = 2 }} };
    try testing.expectEqualDeep(summary, try t.run(io, cmd.xpending("orders", "g")));
    const none: redis.PendingSummary = .{ .count = 0, .first = null, .last = null, .consumers = &.{} };
    try testing.expectEqualDeep(none, try t.run(io, cmd.xpending("orders", "g")));
    const pending: []const redis.Pending = &.{.{ .id = first, .consumer = "c1", .idle = .fromMilliseconds(61000), .deliveries = 1 }};
    try testing.expectEqualDeep(pending, try t.run(io, cmd.xpendingRange("orders", "g", .{ .count = 10, .min_idle = .fromSeconds(60) })));
    try testing.expectEqualDeep(@as([]const redis.Pending, &.{}), try t.run(io, cmd.xpendingRange("orders", "g", .{ .count = 10, .start = .{ .ms = 5, .seq = 1 }, .end = .{ .ms = 9, .seq = 0 }, .consumer = "c1" })));
    const claimed: redis.Claimed(Order) = .{ .next = .zero, .entries = &.{order}, .deleted = &.{second} };
    try testing.expectEqualDeep(claimed, try t.run(io, cmd.xautoclaim(Order, "orders", .{ .group = "g", .consumer = "c2", .min_idle = .fromSeconds(60) })));
    const nothing: redis.Claimed(Order) = .{ .next = .zero, .entries = &.{}, .deleted = &.{} };
    try testing.expectEqualDeep(nothing, try t.run(io, cmd.xautoclaim(Order, "orders", .{ .group = "g", .consumer = "c2", .min_idle = .fromMilliseconds(100), .start = .{ .ms = 5, .seq = 1 }, .count = 25 })));
    try server.finish(io);
}

test "no fields, a field that is NaN, no ids, a min_idle under 1 ms or too long and a timeout under 1 ms are InvalidArgument, and nothing goes out" {
    try within5s(testing.io, refused, .{testing.io});
}

fn refused(io: Io) !void {
    var server: FakeServer = try .start(testing.allocator, io, &.{});
    defer server.stop(io);
    var t: Fixture = undefined;
    try t.init(io, &server);
    defer t.deinit();

    const no_fields: []const redis.FieldValue = &.{};
    try testing.expectError(error.InvalidArgument, t.run(io, cmd.xadd("orders", no_fields, .{})));
    try testing.expectEqualStrings("redis.cmd.xadd: no field to write: a hash takes at least one", t.d.message());
    try testing.expectError(error.InvalidArgument, t.run(io, cmd.xadd("orders", Order{ .id = 7, .total = std.math.nan(f64) }, .{})));
    try testing.expectEqualStrings("redis.cmd.xadd: field 'total' is NaN, which a server does not take", t.d.message());
    try testing.expectError(error.InvalidArgument, t.run(io, cmd.xack("orders", "g", &.{})));
    try testing.expectEqualStrings("redis.cmd.xack: no ids: XACK takes one or more", t.d.message());
    try testing.expectError(error.InvalidArgument, t.run(io, cmd.xdel("orders", &.{})));
    try testing.expectEqualStrings("redis.cmd.xdel: no ids: XDEL takes one or more", t.d.message());
    try testing.expectError(error.InvalidArgument, t.run(io, cmd.xautoclaim(Order, "orders", .{ .group = "g", .consumer = "c2", .min_idle = .fromSeconds(-1) })));
    try testing.expectEqualStrings("redis.cmd.xautoclaim: .min_idle is under 1 ms: give 1 ms or more", t.d.message());
    try testing.expectError(error.InvalidArgument, t.run(io, cmd.xautoclaim(Order, "orders", .{ .group = "g", .consumer = "c2", .min_idle = .max })));
    try testing.expectEqualStrings("redis.cmd.xautoclaim: .min_idle is longer than 9223372036854775807 ms, the most the client counts", t.d.message());
    try testing.expectError(error.InvalidArgument, t.run(io, cmd.xpendingRange("orders", "g", .{ .count = 10, .min_idle = .max })));
    try testing.expectEqualStrings("redis.cmd.xpendingRange: .min_idle is longer than 9223372036854775807 ms, the most the client counts", t.d.message());
    try testing.expectError(error.InvalidArgument, t.run(io, cmd.xread(Order, "orders", .{ .after = .latest, .block = .{ .at_most = .fromMicroseconds(500) } })));
    try testing.expectEqualStrings("redis.cmd.xread: the timeout .at_most is under 1 ms, which a server takes as forever: give 1 ms or more, or .forever", t.d.message());
    try testing.expectError(error.InvalidArgument, t.run(io, cmd.xreadgroup(Order, "orders", .{ .group = "g", .consumer = "c1", .block = .{ .at_most = .max } })));
    try testing.expectEqualStrings("redis.cmd.xreadgroup: the timeout .at_most is longer than 9223372036854775807 ms, the most the client counts", t.d.message());
    try testing.expectEqual(@as(usize, 0), server.received(io));
}
