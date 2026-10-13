//! The client against a fake server on loopback. Each test starts its own
//! server function in a task and cancels it on the way out; the client's
//! waits are bounded, so a mistake fails a test instead of hanging it.

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const testing = std.testing;
const nats = @import("../root.zig");
const Client = nats.Client;
const FakeServer = @import("FakeServer.zig");
const golden = @import("../protocol/golden.zig");

/// The server's side of the handshake, with headers.
fn handshake(peer: *FakeServer.Peer) !void {
    try peer.send(golden.info_default);
    const connect_line = try peer.readLine();
    if (!std.mem.startsWith(u8, connect_line, "CONNECT {")) return error.TestNotConnect;
    try peer.expectLine("PING");
    // A real server sends a second INFO right after the first PONG.
    try peer.send(golden.pong ++ golden.info_connected);
}

/// A handshake, then a PONG for every PING until the client hangs up.
fn serveNormally(io: Io, listener: *net.Server) !void {
    var peer: FakeServer.Peer = undefined;
    try peer.accept(io, listener);
    defer peer.close();
    try handshake(&peer);
    while (try peer.nextLine()) |line| {
        if (std.mem.eql(u8, line, "PING")) {
            try peer.send(golden.pong);
        } else if (!std.mem.eql(u8, line, "PONG")) {
            return error.TestUnexpectedLine;
        }
    }
}

const quick: nats.FlushOptions = .{ .timeout = .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } } };

test "connect, flush, rtt and close" {
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var server = try io.concurrent(serveNormally, .{ io, &listener });
    defer server.cancel(io) catch {};
    var url: [64]u8 = undefined;
    var client: Client = try .init(testing.allocator, io, .{ .servers = &.{try FakeServer.url(&listener, &url)} });
    defer client.deinit();

    try client.connect();
    try testing.expect(client.isConnected());
    try testing.expectEqual(.connected, client.state());
    const server_address = client.connectedServer() orelse return error.TestNotConnected;
    try testing.expectEqualStrings("127.0.0.1", server_address.host());
    try client.flush(quick);
    const round_trip = try client.rtt(quick);
    try testing.expect(round_trip.nanoseconds >= 0);
    const info = (try client.serverInfo(testing.allocator)) orelse return error.TestNoInfo;
    defer info.deinit();
    try testing.expectEqualStrings("2.15.1", info.value.version);

    // A second connect() changes nothing.
    try client.connect();
    try testing.expect(client.isConnected());

    client.close();
    try testing.expectEqual(.closed, client.state());
    try testing.expect(client.connectedServer() == null);
    try testing.expect(try client.serverInfo(testing.allocator) == null);
    try testing.expectError(error.ConnectionClosed, client.flush(quick));
    try testing.expectError(error.ConnectionClosed, client.connect());
    client.close();
    try server.await(io);
}
