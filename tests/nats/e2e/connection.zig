//! Connecting, PING and PONG, credentials and closing, on live servers.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const nats = @import("nats");
const e2e = @import("root.zig");

fn elapsedSince(io: Io, start: Io.Timestamp) Io.Duration {
    return start.durationTo(Io.Clock.awake.now(io));
}

fn connectFlushRttClose(io: Io) !void {
    var client: nats.Client = try .init(testing.allocator, io, .{ .servers = &.{e2e.servers.plain}, .name = "zefir-e2e" });
    defer client.deinit();
    try client.connect();
    try testing.expect(client.isConnected());
    const server = client.connectedServer() orelse return error.TestNotConnected;
    try testing.expectEqual(14222, server.port);

    try client.flush(.{});
    const round_trip = try client.rtt(.{});
    try testing.expect(round_trip.nanoseconds > 0);
    try testing.expect(round_trip.toSeconds() < 1);

    const info = (try client.serverInfo(testing.allocator)) orelse return error.TestNoInfo;
    defer info.deinit();
    try testing.expectEqualStrings("2.15.0", info.value.version);
    try testing.expect(info.value.headers);

    client.close();
    try testing.expectEqual(.closed, client.state());
    try testing.expectError(error.ConnectionClosed, client.flush(.{}));
}

test "connect, flush, rtt and close" {
    try e2e.onZio(connectFlushRttClose);
}

fn heartbeat(io: Io) !void {
    var client: nats.Client = try .init(testing.allocator, io, .{
        .servers = &.{e2e.servers.plain},
        .ping_interval = .fromMilliseconds(50),
        .max_outstanding_pings = 2,
    });
    defer client.deinit();
    try client.connect();
    // Eight heartbeat PINGs, each answered in time.
    try io.sleep(.fromMilliseconds(400), .awake);
    try testing.expect(client.isConnected());
    try client.flush(.{});
}

test "the server answers the heartbeat, so the connection stays" {
    try e2e.onZio(heartbeat);
}

fn connectAs(io: Io, auth: nats.Auth) !void {
    var client: nats.Client = try .init(testing.allocator, io, .{ .servers = &.{e2e.servers.auth}, .auth = auth });
    defer client.deinit();
    try client.connect();
    try client.flush(.{});
}

fn expectRefused(io: Io, auth: nats.Auth) !void {
    var client: nats.Client = try .init(testing.allocator, io, .{ .servers = &.{e2e.servers.auth}, .auth = auth });
    defer client.deinit();
    try testing.expectError(error.AuthenticationFailed, client.connect());
    try testing.expectEqual(.closed, client.state());
}

fn credentials(io: Io) !void {
    try connectAs(io, .{ .user_password = .{ .username = "alice", .password = "secret" } });
    // Quotes, a backslash and non-ASCII letters survive CONNECT's JSON.
    try connectAs(io, .{ .user_password = .{ .username = "carol", .password = "p\"w\\d-пароль-ü" } });
    try expectRefused(io, .{ .user_password = .{ .username = "alice", .password = "wrong" } });
    try expectRefused(io, .none);
}

test "user and password: right, wrong, missing, and with quotes and unicode" {
    try e2e.onZio(credentials);
}

fn tlsRequired(io: Io) !void {
    var client: nats.Client = try .init(testing.allocator, io, .{
        .servers = &.{e2e.servers.tls},
        .auth = .{ .user_password = .{ .username = "alice", .password = "secret" } },
    });
    defer client.deinit();
    try testing.expectError(error.UnsupportedSecurityFeature, client.connect());
}

test "a server that requires TLS: UnsupportedSecurityFeature before the password goes out" {
    try e2e.onZio(tlsRequired);
}

fn tlsFirst(io: Io) !void {
    // The server waits for a TLS handshake and sends nothing.
    {
        var client: nats.Client = try .init(testing.allocator, io, .{
            .servers = &.{e2e.servers.tls_first},
            .connect_timeout = .fromMilliseconds(500),
        });
        defer client.deinit();
        const start = Io.Clock.awake.now(io);
        try testing.expectError(error.Timeout, client.connect());
        try testing.expect(elapsedSince(io, start).toMilliseconds() >= 500);
    }
    // After its TLS timeout of 2 s the server hangs up, before any INFO.
    {
        var client: nats.Client = try .init(testing.allocator, io, .{
            .servers = &.{e2e.servers.tls_first},
            .connect_timeout = .fromSeconds(4),
        });
        defer client.deinit();
        try testing.expectError(error.Disconnected, client.connect());
    }
}

test "a TLS-first server: Timeout, or Disconnected once it hangs up" {
    try e2e.onZio(tlsFirst);
}
