//! The stream commands of `redis.cmd` against the server that REDIS_IMAGE
//! names, on redis-plain: entries of a struct added and read back by
//! range and by XREAD, deleted and trimmed; a group and its consumers:
//! XREADGROUP without XACK, XPENDING, XAUTOCLAIM of the entries another
//! consumer left pending, XACK, an entry deleted while pending that comes
//! back with `fields == null`; and XREADGROUP with BLOCK under a deadline,
//! on a server with the default `hz`.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const redis = @import("redis");
const cmd = redis.cmd;
const e2e = @import("root.zig");
const within = e2e.within;
const Session = e2e.Session;

const Order = struct { id: i64, total: f64 };

test "entries of a struct go in with XADD and come back by XRANGE, XREVRANGE and XREAD; XLEN, XDEL, XTRIM; xaddNoMkstream adds to a stream that is there, and to one that is not nothing: null" {
    try e2e.onZio(entries);
}

fn entries(io: Io) !void {
    var s: Session = undefined;
    try s.open(io);
    defer s.close();
    const k = "e2e:stream:entries";
    const none = "e2e:stream:none";
    _ = try s.run(cmd.del(&.{ k, none }));

    const first = try s.run(cmd.xadd(k, Order{ .id = 1, .total = 10.5 }, .{}));
    const second = try s.run(cmd.xadd(k, &.{ .{ .field = "id", .value = "2" }, .{ .field = "total", .value = "20" } }, .{ .max_len = 1000 }));
    const third_id: redis.StreamId = .{ .ms = second.ms, .seq = second.seq + 1 };
    try testing.expectEqual(third_id, try s.run(cmd.xadd(k, Order{ .id = 3, .total = 30 }, .{ .id = third_id, .max_len = 1000, .approximate = false })));
    try testing.expectEqual(@as(u64, 3), try s.run(cmd.xlen(k)));

    const all: []const redis.Entry(Order) = &.{
        .{ .id = first, .fields = .{ .id = 1, .total = 10.5 } },
        .{ .id = second, .fields = .{ .id = 2, .total = 20 } },
        .{ .id = third_id, .fields = .{ .id = 3, .total = 30 } },
    };
    try testing.expectEqualDeep(all, try s.run(cmd.xrange(Order, k, .{})));
    try testing.expectEqualDeep(all[1..2], try s.run(cmd.xrange(Order, k, .{ .start = second, .count = 1 })));
    try testing.expectEqualDeep(@as([]const redis.Entry(Order), &.{ all[2], all[1] }), try s.run(cmd.xrevrange(Order, k, .{ .count = 2 })));
    try testing.expectEqualDeep(all[1..], try s.run(cmd.xread(Order, k, .{ .after = .{ .id = first } })));
    try testing.expectEqualDeep(@as([]const redis.Entry(Order), &.{}), try s.run(cmd.xread(Order, k, .{ .after = .{ .id = third_id } })));

    try testing.expectEqual(@as(u64, 1), try s.run(cmd.xdel(k, &.{ second, .{ .ms = 1, .seq = 0 } })));
    try testing.expectEqual(@as(u64, 1), try s.run(cmd.xtrim(k, .{ .max_len = 1 }, .{ .approximate = false })));
    try testing.expectEqualDeep(all[2..], try s.run(cmd.xrange(Order, k, .{})));
    try testing.expectEqual(@as(u64, 0), try s.run(cmd.xtrim(k, .{ .min_id = third_id }, .{})));

    const fourth = (try s.run(cmd.xaddNoMkstream(k, Order{ .id = 4, .total = 40 }, .{}))) orelse return error.TestUnexpectedResult;
    try testing.expectEqualDeep(@as([]const redis.Entry(Order), &.{ all[2], .{ .id = fourth, .fields = .{ .id = 4, .total = 40 } } }), try s.run(cmd.xrange(Order, k, .{})));
    try testing.expectEqual(@as(?redis.StreamId, null), try s.run(cmd.xaddNoMkstream(none, Order{ .id = 5, .total = 50 }, .{})));
    try testing.expectEqual(@as(u64, 0), try s.run(cmd.exists(&.{none})));
}

test "a group: XREADGROUP without XACK leaves the entries pending, XPENDING counts them, XAUTOCLAIM hands them to another consumer, XACK takes one off, an entry deleted while pending comes back with fields null; a second XGROUP CREATE is BUSYGROUP" {
    try e2e.onZio(groups);
}

fn groups(io: Io) !void {
    var s: Session = undefined;
    try s.open(io);
    defer s.close();
    const k = "e2e:stream:groups";
    _ = try s.run(cmd.del(&.{k}));

    try s.run(cmd.xgroupCreate(k, "g", .{ .mkstream = true }));
    var d: redis.Diagnostics = .{};
    try testing.expectError(error.ServerError, s.client.run(io, within(io, .fromSeconds(10)), cmd.xgroupCreate(k, "g", .{}), .{ .diagnostics = &d }));
    try testing.expect(d.isCode("BUSYGROUP"));

    const first = try s.run(cmd.xadd(k, Order{ .id = 1, .total = 10.5 }, .{}));
    const second = try s.run(cmd.xadd(k, Order{ .id = 2, .total = 20 }, .{}));
    const both: []const redis.Entry(Order) = &.{
        .{ .id = first, .fields = .{ .id = 1, .total = 10.5 } },
        .{ .id = second, .fields = .{ .id = 2, .total = 20 } },
    };
    try testing.expectEqualDeep(both, try s.run(cmd.xreadgroup(Order, k, .{ .group = "g", .consumer = "c1" })));
    const summary: redis.PendingSummary = .{ .count = 2, .first = first, .last = second, .consumers = &.{.{ .name = "c1", .count = 2 }} };
    try testing.expectEqualDeep(summary, try s.run(cmd.xpending(k, "g")));

    try io.sleep(.fromMilliseconds(200), .awake);
    const claimed = try s.run(cmd.xautoclaim(Order, k, .{ .group = "g", .consumer = "c2", .min_idle = .fromMilliseconds(100) }));
    try testing.expectEqual(redis.StreamId.zero, claimed.next);
    try testing.expectEqualDeep(both, claimed.entries);
    try testing.expectEqual(@as(usize, 0), claimed.deleted.len);
    const pending = try s.run(cmd.xpendingRange(k, "g", .{ .count = 10, .consumer = "c2" }));
    try testing.expectEqual(@as(usize, 2), pending.len);
    for (pending, [_]redis.StreamId{ first, second }) |p, id| {
        try testing.expectEqual(id, p.id);
        try testing.expectEqualStrings("c2", p.consumer);
        try testing.expectEqual(@as(u64, 2), p.deliveries);
    }
    try testing.expectEqual(@as(usize, 0), (try s.run(cmd.xpendingRange(k, "g", .{ .count = 10, .consumer = "c1" }))).len);

    try testing.expectEqual(@as(u64, 1), try s.run(cmd.xack(k, "g", &.{first})));
    try testing.expectEqual(@as(u64, 1), try s.run(cmd.xdel(k, &.{second})));
    try testing.expectEqualDeep(@as([]const redis.Entry(Order), &.{.{ .id = second, .fields = null }}), try s.run(cmd.xreadgroup(Order, k, .{ .group = "g", .consumer = "c2", .from = .{ .id = .zero } })));
}

test "xreadgroup with .block on an empty stream under a deadline of 1 s returns no entry before it, and its connection stays" {
    try e2e.onZio(blocking);
}

fn blocking(io: Io) !void {
    var s: Session = undefined;
    try s.open(io);
    defer s.close();
    const k = "e2e:stream:block";
    _ = try s.run(cmd.del(&.{k}));
    try s.run(cmd.xgroupCreate(k, "g", .{ .mkstream = true }));

    const before = s.client.stats();
    const began = Io.Clock.awake.now(io);
    try testing.expectEqualDeep(@as([]const redis.Entry(Order), &.{}), try s.runIn(within(io, .fromSeconds(1)), cmd.xreadgroup(Order, k, .{ .group = "g", .consumer = "c1", .block = .{ .at_most = .fromSeconds(30) } })));
    const took = began.durationTo(Io.Clock.awake.now(io)).toMilliseconds();
    if (took < 700 or took >= 1000) {
        std.debug.print("XREADGROUP BLOCK under a deadline of 1 s took {d} ms\n", .{took});
        return error.TestUnexpectedResult;
    }
    const after = s.client.stats();
    try testing.expectEqual(before.connections, after.connections);
    try testing.expectEqual(@as(u64, 0), after.clears);
}
