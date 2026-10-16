//! The adapter of zefir-nats on a live broker, where the transport cannot
//! show it: a burst its subscription cannot hold comes out as SlowConsumer
//! and then what was kept, and `drain` returns at once while the broker
//! confirms it.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const rpc_nats = @import("rpc-nats");
const nats = @import("nats");
const root = @import("root.zig");

const servers = root.servers;

fn scenario(io: Io) !void {
    var nc: nats.Client = try .init(testing.allocator, io, .{ .servers = &.{servers.plain} });
    defer nc.deinit();
    try nc.connect();
    var adapter: rpc_nats.ZefirNats = .{ .client = &nc, .pending = .{ .messages = 2 } };
    const conn = adapter.conn();
    const sub = try conn.subscribe(io, "adapter.burst", null, root.five_seconds);
    defer conn.unsubscribe(io, sub);
    try conn.flush(io, root.five_seconds);

    // Ten messages to a queue of two: the broker sends them all before the
    // PONG of the flush.
    for (0..10) |i| {
        var payload: [8]u8 = undefined;
        try conn.publish(io, .{ .subject = "adapter.burst", .payload = try std.fmt.bufPrint(&payload, "{d}", .{i}) }, root.five_seconds);
    }
    try conn.flush(io, root.five_seconds);
    try testing.expectError(error.SlowConsumer, conn.next(io, sub, root.five_seconds));
    for ([_][]const u8{ "0", "1" }) |kept| {
        const msg = (try conn.next(io, sub, root.five_seconds)).?;
        defer msg.release();
        try testing.expectEqualStrings(kept, msg.payload);
    }
    try testing.expectError(error.Timeout, conn.next(io, sub, .{ .duration = .{ .raw = .fromMilliseconds(100), .clock = .awake } }));

    // A message on its way, then the drain: it returns at once, and the
    // message and the end still come.
    try conn.publish(io, .{ .subject = "adapter.burst", .payload = "last" }, root.five_seconds);
    try conn.flush(io, root.five_seconds);
    const began = Io.Clock.awake.now(io);
    try conn.drain(io, sub);
    try testing.expect(began.durationTo(Io.Clock.awake.now(io)).toMilliseconds() < 100);
    const last = (try conn.next(io, sub, root.five_seconds)).?;
    defer last.release();
    try testing.expectEqualStrings("last", last.payload);
    try testing.expectEqual(@as(?rpc_nats.Conn.InMsg, null), try conn.next(io, sub, root.five_seconds));
}

test "the adapter of zefir-nats tells of dropped messages, and its drain returns at once" {
    try root.onZio(scenario);
}
