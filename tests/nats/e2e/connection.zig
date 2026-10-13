//! Connecting, PING and PONG, and closing, on a live server.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const nats = @import("nats");
const e2e = @import("root.zig");

fn connectAndClose(io: Io) !void {
    var client: nats.Client = try .init(testing.allocator, io, .{ .servers = &.{e2e.servers.plain} });
    defer client.deinit();
    try client.connect();
    try testing.expect(client.isConnected());
    client.close();
    try testing.expectEqual(.closed, client.state());
}

test "connect to a plain server and close" {
    try e2e.onZio(connectAndClose);
}
