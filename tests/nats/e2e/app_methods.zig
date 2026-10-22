//! The methods that zefir.App calls on the client, `start`, `wait` and
//! `shutdown`, on a live server.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const nats = @import("nats");
const e2e = @import("root.zig");

/// Reads `sub` until the drain ends it; returns how many messages came.
fn readToEnd(sub: *nats.Subscription) !u32 {
    var count: u32 = 0;
    while (try sub.next(.{})) |msg| {
        var received = msg;
        received.deinit();
        count += 1;
    }
    return count;
}

fn startShutdownWait(io: Io) !void {
    var client: nats.Client = try .init(testing.allocator, io, .{ .servers = &.{e2e.servers.plain}, .name = "zefir-e2e-app" });
    defer client.deinit();
    try client.start(io);
    try testing.expect(client.isConnected());

    // A subscription with a reader, as a server on the client has.
    const sub = try client.subscribe("e2e.app.methods", .{});
    defer sub.deinit();
    var reader = try io.concurrent(readToEnd, .{sub});
    defer _ = reader.cancel(io) catch {};
    try client.publish("e2e.app.methods", "one");
    try client.flush(.{});

    var watcher = try io.concurrent(nats.Client.wait, .{ &client, io });
    defer watcher.cancel(io) catch {};
    const deadline: Io.Clock.Timestamp = .fromNow(io, .{ .raw = .fromSeconds(10), .clock = .awake });
    try client.shutdown(io, deadline);
    try testing.expectEqual(.closed, client.state());
    try testing.expectEqual(nats.CloseReason.drained, client.close_reason.?);
    // A drained client closed on request: no failure for App.
    try watcher.await(io);
    try testing.expectEqual(1, try reader.await(io));
}

test "start, shutdown and wait against a NATS server" {
    try e2e.onZio(startShutdownWait);
}
