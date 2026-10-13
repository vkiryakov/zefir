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
const time = @import("../engine/time.zig");

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

/// Waits until the client reaches `expected`, for 5 s at most.
fn awaitState(client: *Client, expected: nats.State) !void {
    const io = client.io;
    const give_up = time.after(io, .fromSeconds(5));
    while (client.state() != expected) {
        if (time.expired(io, give_up)) return error.TestStateNeverReached;
        try io.sleep(.fromMilliseconds(2), .awake);
    }
}

/// Waits until `event` is set, for 5 s at most.
fn awaitEvent(io: Io, event: *Io.Event) !void {
    const give_up = time.after(io, .fromSeconds(5));
    while (!event.isSet()) {
        event.waitTimeout(io, .{ .deadline = give_up }) catch |err| switch (err) {
            // Io.Event reports a spurious wakeup as Timeout too.
            error.Timeout => if (time.expired(io, give_up)) return error.TestEventNeverSet,
            error.Canceled => return err,
        };
    }
}

fn elapsedSince(io: Io, start: Io.Timestamp) Io.Duration {
    return start.durationTo(Io.Clock.awake.now(io));
}

const second_info = "INFO {\"server_id\":\"second\",\"version\":\"2.15.1\",\"proto\":1,\"headers\":true,\"max_payload\":2048} \r\n";

/// INFO number two right after the first PONG and a PING of its own; then
/// PONGs for the client's PINGs. The client must have answered the PING
/// by the time it hangs up.
fn serveSecondInfo(io: Io, listener: *net.Server) !void {
    var peer: FakeServer.Peer = undefined;
    try peer.accept(io, listener);
    defer peer.close();
    try peer.send(golden.info_default);
    _ = try peer.readLine();
    try peer.expectLine("PING");
    try peer.send(golden.pong ++ second_info ++ golden.ping);
    var answered = false;
    while (try peer.nextLine()) |line| {
        if (std.mem.eql(u8, line, "PING")) try peer.send(golden.pong);
        if (std.mem.eql(u8, line, "PONG")) answered = true;
    }
    if (!answered) return error.TestPingNotAnswered;
}

test "a later INFO replaces the first, and a server PING gets its PONG" {
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var server = try io.concurrent(serveSecondInfo, .{ io, &listener });
    defer server.cancel(io) catch {};
    var url: [64]u8 = undefined;
    var client: Client = try .init(testing.allocator, io, .{ .servers = &.{try FakeServer.url(&listener, &url)} });
    defer client.deinit();
    try client.connect();

    const give_up = time.after(io, .fromSeconds(5));
    while (true) {
        const info = (try client.serverInfo(testing.allocator)) orelse return error.TestNoInfo;
        defer info.deinit();
        if (std.mem.eql(u8, info.value.server_id, "second")) {
            try testing.expectEqual(2048, info.value.max_payload);
            break;
        }
        if (time.expired(io, give_up)) return error.TestInfoNeverReplaced;
        try io.sleep(.fromMilliseconds(2), .awake);
    }
    // The PONG to the server's PING goes out before this flush returns.
    try client.flush(quick);
    client.close();
    try server.await(io);
}

/// A handshake, then silence: PINGs are read and counted, never answered.
fn serveSilently(io: Io, listener: *net.Server, pings: *usize) !void {
    var peer: FakeServer.Peer = undefined;
    try peer.accept(io, listener);
    defer peer.close();
    try handshake(&peer);
    while (try peer.nextLine()) |line| {
        if (std.mem.eql(u8, line, "PING")) pings.* += 1;
    }
}

test "a server that stops answering is dropped after max_outstanding_pings PINGs" {
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var pings: usize = 0;
    var server = try io.concurrent(serveSilently, .{ io, &listener, &pings });
    defer server.cancel(io) catch {};
    var url: [64]u8 = undefined;
    var client: Client = try .init(testing.allocator, io, .{
        .servers = &.{try FakeServer.url(&listener, &url)},
        .ping_interval = .fromMilliseconds(50),
        .max_outstanding_pings = 2,
    });
    defer client.deinit();
    const start = Io.Clock.awake.now(io);
    try client.connect();
    try awaitState(&client, .closed);
    // Two PINGs go out unanswered; the third interval finds them so.
    try testing.expect(elapsedSince(io, start).toMilliseconds() >= 100);
    try testing.expectError(error.ConnectionClosed, client.flush(quick));
    try server.await(io);
    try testing.expectEqual(2, pings);
}

/// A handshake; at the client's first PING the server hangs up instead.
fn serveAndHangUp(io: Io, listener: *net.Server) !void {
    var peer: FakeServer.Peer = undefined;
    try peer.accept(io, listener);
    defer peer.close();
    try handshake(&peer);
    try peer.expectLine("PING");
}

test "a server that hangs up closes the client, and a waiting flush learns it" {
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var server = try io.concurrent(serveAndHangUp, .{ io, &listener });
    defer server.cancel(io) catch {};
    var url: [64]u8 = undefined;
    var client: Client = try .init(testing.allocator, io, .{ .servers = &.{try FakeServer.url(&listener, &url)} });
    defer client.deinit();
    try client.connect();
    try testing.expectError(error.ConnectionClosed, client.flush(quick));
    try awaitState(&client, .closed);
    try testing.expect(client.connectedServer() == null);
    try server.await(io);
}

fn serveAndCount(io: Io, listener: *net.Server, first: []const u8, received: *usize) !void {
    var peer: FakeServer.Peer = undefined;
    try peer.accept(io, listener);
    defer peer.close();
    try peer.send(first);
    received.* = try peer.readToEnd();
}

test "a server that wants TLS: UnsupportedSecurityFeature, and the password never leaves" {
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var received: usize = std.math.maxInt(usize);
    var server = try io.concurrent(serveAndCount, .{ io, &listener, "INFO " ++ golden.info_tls_json ++ " \r\n", &received });
    defer server.cancel(io) catch {};
    var url: [64]u8 = undefined;
    var client: Client = try .init(testing.allocator, io, .{
        .servers = &.{try FakeServer.url(&listener, &url)},
        .auth = .{ .user_password = .{ .username = "alice", .password = "secret" } },
    });
    defer client.deinit();
    try testing.expectError(error.UnsupportedSecurityFeature, client.connect());
    try testing.expectEqual(.closed, client.state());
    try server.await(io);
    try testing.expectEqual(0, received);
}

fn serveAuthViolation(io: Io, listener: *net.Server) !void {
    var peer: FakeServer.Peer = undefined;
    try peer.accept(io, listener);
    defer peer.close();
    try peer.send("INFO " ++ golden.info_auth_json ++ " \r\n");
    _ = try peer.readLine();
    try peer.expectLine("PING");
    try peer.send("-ERR 'Authorization Violation'\r\n");
    _ = try peer.readToEnd();
}

test "a wrong password: AuthenticationFailed" {
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var server = try io.concurrent(serveAuthViolation, .{ io, &listener });
    defer server.cancel(io) catch {};
    var url: [64]u8 = undefined;
    var client: Client = try .init(testing.allocator, io, .{
        .servers = &.{try FakeServer.url(&listener, &url)},
        .auth = .{ .user_password = .{ .username = "alice", .password = "wrong" } },
    });
    defer client.deinit();
    try testing.expectError(error.AuthenticationFailed, client.connect());
    try testing.expectEqual(.closed, client.state());
    try server.await(io);
}

test "a server that never sends INFO, as with TLS first: Timeout" {
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var received: usize = std.math.maxInt(usize);
    var server = try io.concurrent(serveAndCount, .{ io, &listener, "", &received });
    defer server.cancel(io) catch {};
    var url: [64]u8 = undefined;
    var client: Client = try .init(testing.allocator, io, .{
        .servers = &.{try FakeServer.url(&listener, &url)},
        .connect_timeout = .fromMilliseconds(100),
    });
    defer client.deinit();
    const start = Io.Clock.awake.now(io);
    try testing.expectError(error.Timeout, client.connect());
    const waited = elapsedSince(io, start);
    try testing.expect(waited.toMilliseconds() >= 100);
    try testing.expect(waited.toSeconds() < 5);
    try server.await(io);
    try testing.expectEqual(0, received);
}

/// A handshake; then PINGs are noted and never answered.
fn serveDeaf(io: Io, listener: *net.Server, ping_seen: *Io.Event) !void {
    var peer: FakeServer.Peer = undefined;
    try peer.accept(io, listener);
    defer peer.close();
    try handshake(&peer);
    while (try peer.nextLine()) |line| {
        if (std.mem.eql(u8, line, "PING")) ping_seen.set(io);
    }
}

fn flushLong(client: *Client) Client.FlushError!void {
    return client.flush(.{ .timeout = .{ .duration = .{ .raw = .fromSeconds(30), .clock = .awake } } });
}

test "close() while another task waits in flush: ConnectionClosed at once" {
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var ping_seen: Io.Event = .unset;
    var server = try io.concurrent(serveDeaf, .{ io, &listener, &ping_seen });
    defer server.cancel(io) catch {};
    var url: [64]u8 = undefined;
    var client: Client = try .init(testing.allocator, io, .{ .servers = &.{try FakeServer.url(&listener, &url)} });
    defer client.deinit();
    try client.connect();

    var flusher = try io.concurrent(flushLong, .{&client});
    defer flusher.cancel(io) catch {};
    try awaitEvent(io, &ping_seen);
    const start = Io.Clock.awake.now(io);
    client.close();
    try testing.expectError(error.ConnectionClosed, flusher.await(io));
    try testing.expect(elapsedSince(io, start).toSeconds() < 1);
    try server.await(io);
}

/// A handshake; at the client's first PING, a -ERR that ends the
/// connection instead of PONG.
fn serveFatalError(io: Io, listener: *net.Server) !void {
    var peer: FakeServer.Peer = undefined;
    try peer.accept(io, listener);
    defer peer.close();
    try handshake(&peer);
    try peer.expectLine("PING");
    try peer.send("-ERR 'Stale Connection'\r\n");
    _ = try peer.readToEnd();
}

test "a -ERR that ends the connection closes the client" {
    // The client logs the server's error as a warning; this test expects it.
    testing.log_level = .err;
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var server = try io.concurrent(serveFatalError, .{ io, &listener });
    defer server.cancel(io) catch {};
    var url: [64]u8 = undefined;
    var client: Client = try .init(testing.allocator, io, .{ .servers = &.{try FakeServer.url(&listener, &url)} });
    defer client.deinit();
    try client.connect();
    try testing.expectError(error.ConnectionClosed, client.flush(quick));
    try awaitState(&client, .closed);
    try server.await(io);
}

test "connect tries the servers in order" {
    const io = testing.io;
    // A port nobody listens on comes first.
    var gone = try FakeServer.listen(io);
    var gone_url: [64]u8 = undefined;
    const dead = try FakeServer.url(&gone, &gone_url);
    gone.deinit(io);

    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var server = try io.concurrent(serveNormally, .{ io, &listener });
    defer server.cancel(io) catch {};
    var url: [64]u8 = undefined;
    var client: Client = try .init(testing.allocator, io, .{ .servers = &.{ dead, try FakeServer.url(&listener, &url) } });
    defer client.deinit();
    try client.connect();
    const server_address = client.connectedServer() orelse return error.TestNotConnected;
    try testing.expectEqual(listener.socket.address.getPort(), server_address.port);
    client.close();
    try server.await(io);
}
