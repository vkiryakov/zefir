//! The pool of servers, reconnect, lame duck, refused credentials, drain,
//! events and statistics against fake servers on loopback. Each test starts
//! its own server function in a task and cancels it on the way out; the
//! client's waits are bounded, so a mistake fails a test instead of hanging
//! it.

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const testing = std.testing;
const nats = @import("../root.zig");
const Client = nats.Client;
const FakeServer = @import("FakeServer.zig");
const golden = @import("../protocol/golden.zig");
const time = @import("../engine/time.zig");

const quick: nats.FlushOptions = .{ .timeout = .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } } };

/// The server's side of the handshake with `info` as its INFO.
fn handshake(peer: *FakeServer.Peer, info: []const u8) !void {
    try peer.send(info);
    const connect_line = try peer.readLine();
    if (!std.mem.startsWith(u8, connect_line, "CONNECT {")) return error.TestNotConnect;
    try peer.expectLine("PING");
    try peer.send(golden.pong);
}

/// Answers every PING until the client hangs up.
fn answerPings(peer: *FakeServer.Peer) !void {
    while (try peer.nextLine()) |line| {
        if (std.mem.eql(u8, line, "PING")) try peer.send(golden.pong);
    }
}

/// Node A of a cluster announces itself and 14235; at the client's next
/// PING, 14235 has left the cluster.
fn serveCluster(io: Io, listener: *net.Server) !void {
    var peer: FakeServer.Peer = undefined;
    try peer.accept(io, listener);
    defer peer.close();
    try handshake(&peer, "INFO " ++ golden.info_cluster_json ++ " \r\n");
    try peer.expectLine("PING");
    try peer.send("INFO {\"server_id\":\"A\",\"proto\":1,\"headers\":true,\"connect_urls\":[\"127.0.0.1:14234\"]} \r\n" ++ golden.pong);
    try answerPings(&peer);
}

test "the servers a cluster announces join the pool, and leave it when no longer announced" {
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var server = try io.concurrent(serveCluster, .{ io, &listener });
    defer server.cancel(io) catch {};
    var url: [64]u8 = undefined;
    var client: Client = try .init(testing.allocator, io, .{ .servers = &.{try FakeServer.url(&listener, &url)}, .randomize_servers = false });
    defer client.deinit();
    try client.connect();

    var buffer: [8]nats.ServerAddress = undefined;
    const announced = client.discoveredServers(&buffer);
    try testing.expectEqual(2, announced.len);
    try testing.expectEqual(14234, announced[0].port);
    try testing.expectEqual(14235, announced[1].port);
    // The INFO that drops 14235 comes before the PONG of this flush.
    try client.flush(quick);
    const left = client.discoveredServers(&buffer);
    try testing.expectEqual(1, left.len);
    try testing.expectEqual(14234, left[0].port);
    client.close();
    try server.await(io);
}

test "ignore_discovered_servers keeps the pool to the servers of the options" {
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var server = try io.concurrent(serveCluster, .{ io, &listener });
    defer server.cancel(io) catch {};
    var url: [64]u8 = undefined;
    var client: Client = try .init(testing.allocator, io, .{ .servers = &.{try FakeServer.url(&listener, &url)}, .ignore_discovered_servers = true });
    defer client.deinit();
    try client.connect();
    try client.flush(quick);
    var buffer: [8]nats.ServerAddress = undefined;
    try testing.expectEqual(0, client.discoveredServers(&buffer).len);
    client.close();
    try server.await(io);
}
