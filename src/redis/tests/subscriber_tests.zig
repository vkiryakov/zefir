//! Tests of `redis.Client.subscribe` and `redis.Subscriber` against
//! `redis.testing.FakeServer` and `FakeServer.Peer` over loopback: the
//! subscription on a connection of its own, with the handshake of the
//! pool's, both commands in one write, and its refusals. Every test runs
//! under a time limit of 5 s.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const core = @import("core");
const redis = @import("../root.zig");
const Client = redis.Client;
const Diagnostics = redis.Diagnostics;
const FakeServer = redis.testing.FakeServer;
const Peer = FakeServer.Peer;
const time = @import("../engine/time.zig");
const peers = @import("peers.zig");
const within5s = @import("time_limit.zig").within5s;

fn within(io: Io, duration: Io.Duration) redis.OperationContext {
    return .of(core.Context.root.withDeadline(.after(time.now(io), duration)));
}

/// A client of `options`, connected.
fn connected(io: Io, client: *Client, options: Client.Options) !void {
    client.* = try .init(testing.allocator, io, options);
    errdefer client.deinit();
    try client.connect(io, .root, null);
}

/// The confirmation of `PSUBSCRIBE events.*`, the second subscription of
/// the connection.
const psubscribed: FakeServer.Reply = .{ .push = &.{ .{ .string = "psubscribe" }, .{ .string = "events.*" }, .{ .integer = 2 } } };

test "subscribe sends SUBSCRIBE and PSUBSCRIBE on a connection of its own and returns once the server confirmed both; stats count the subscriber, not a connection of the pool" {
    try within5s(testing.io, subscribes, .{testing.io});
}

fn subscribes(io: Io) !void {
    var server: FakeServer = try .start(testing.allocator, io, &.{
        .expect(.{ "SUBSCRIBE", "orders", "news" }, .subscribed(&.{ "orders", "news" })),
        .expect(.{ "PSUBSCRIBE", "events.*" }, .{ .push = &.{ .{ .string = "psubscribe" }, .{ .string = "events.*" }, .{ .integer = 3 } } }),
    });
    defer server.stop(io);
    var client: Client = undefined;
    try connected(io, &client, .{ .url = server.url() });
    defer client.deinit();
    var sub = try client.subscribe(io, .of(.root), .{ .channels = &.{ "orders", "news" }, .patterns = &.{"events.*"} });
    defer sub.close(io);
    const stats = client.stats();
    try testing.expectEqual(@as(usize, 1), stats.subscribers);
    try testing.expectEqual(@as(usize, 1), stats.connections);
    try testing.expectEqual(@as(usize, 2), server.received(io));
    // The pool's connection is the first; the subscriber has the second.
    for (0..2) |i| try testing.expectEqual(@as(u32, 2), (try server.entry(io, i)).connection);
    sub.close(io);
    try testing.expectEqual(@as(usize, 0), client.stats().subscribers);
    try server.finish(io);
}

test "only the list that has names goes out: SUBSCRIBE alone, or PSUBSCRIBE alone" {
    try within5s(testing.io, oneList, .{testing.io});
}

fn oneList(io: Io) !void {
    var server: FakeServer = try .start(testing.allocator, io, &.{
        .expect(.{ "SUBSCRIBE", "orders" }, .subscribed(&.{"orders"})),
        .expect(.{ "PSUBSCRIBE", "events.*" }, .{ .push = &.{ .{ .string = "psubscribe" }, .{ .string = "events.*" }, .{ .integer = 1 } } }),
    });
    defer server.stop(io);
    var client: Client = undefined;
    try connected(io, &client, .{ .url = server.url() });
    defer client.deinit();
    var channels = try client.subscribe(io, .of(.root), .{ .channels = &.{"orders"} });
    defer channels.close(io);
    var patterns = try client.subscribe(io, .of(.root), .{ .patterns = &.{"events.*"} });
    defer patterns.close(io);
    try testing.expectEqual(@as(usize, 2), server.received(io));
    try testing.expectEqual(@as(u32, 2), (try server.entry(io, 0)).connection);
    try testing.expectEqual(@as(u32, 3), (try server.entry(io, 1)).connection);
    try server.finish(io);
}

/// `client.subscribe` from a task of its own.
fn subscribeTo(client: *Client, io: Io, options: redis.SubscribeOptions) redis.Error!redis.Subscriber {
    return client.subscribe(io, .of(.root), options);
}

/// A subscribe in a task of its own, which the test awaits once. If the
/// test fails first, `abandon` cancels it and closes the subscriber it may
/// have made: a client must not go with a subscriber open.
const Subscribing = struct {
    future: Io.Future(redis.Error!redis.Subscriber),
    awaited: bool = false,

    fn start(io: Io, client: *Client, options: redis.SubscribeOptions) !Subscribing {
        return .{ .future = try io.concurrent(subscribeTo, .{ client, io, options }) };
    }

    fn await(s: *Subscribing, io: Io) redis.Error!redis.Subscriber {
        s.awaited = true;
        return s.future.await(io);
    }

    fn abandon(s: *Subscribing, io: Io) void {
        if (s.awaited) return;
        if (s.future.cancel(io)) |sub| {
            var left = sub;
            left.close(io);
        } else |_| {}
    }
};

/// Accepts the client's first connection on `peer` and shakes hands on it,
/// while the client connects.
fn connectThrough(io: Io, peer: *Peer, client: *Client) !void {
    var connecting = try io.concurrent(Client.connect, .{ client, io, core.Context.root, null });
    defer connecting.cancel(io) catch {};
    try peer.accept(io);
    try peers.shakeHands(peer, io, .zero);
    try connecting.await(io);
}

test "SUBSCRIBE and PSUBSCRIBE both go out before the server confirms either, after the handshake of every connection" {
    try within5s(testing.io, oneWrite, .{testing.io});
}

fn oneWrite(io: Io) !void {
    var peer: Peer = try .listen(io);
    defer peer.close(io);
    var client: Client = try .init(testing.allocator, io, .{ .url = peer.url() });
    defer client.deinit();
    try connectThrough(io, &peer, &client);
    var subscribing: Subscribing = try .start(io, &client, .{ .channels = &.{"orders"}, .patterns = &.{"events.*"} });
    defer subscribing.abandon(io);
    // The subscriber's own connection: the pool's closes on the peer's
    // side, and nothing uses it again.
    try peer.accept(io);
    try peers.shakeHands(&peer, io, .zero);
    try peers.expectCommand(&peer, &.{ "SUBSCRIBE", "orders" });
    try peers.expectCommand(&peer, &.{ "PSUBSCRIBE", "events.*" });
    try peer.send(">3\r\n$9\r\nsubscribe\r\n$6\r\norders\r\n:1\r\n>3\r\n$10\r\npsubscribe\r\n$8\r\nevents.*\r\n:2\r\n");
    var sub = try subscribing.await(io);
    defer sub.close(io);
    try testing.expectEqual(@as(usize, 1), client.stats().subscribers);
}

test "NOPERM for a channel is a ServerError of subscribe, with the server's code, and the subscriber's connection closes" {
    try within5s(testing.io, refusedChannel, .{testing.io});
}

fn refusedChannel(io: Io) !void {
    var peer: Peer = try .listen(io);
    defer peer.close(io);
    var client: Client = try .init(testing.allocator, io, .{ .url = peer.url() });
    defer client.deinit();
    try connectThrough(io, &peer, &client);
    var d: Diagnostics = .{};
    var subscribing: Subscribing = try .start(io, &client, .{ .channels = &.{"news"}, .diagnostics = &d });
    defer subscribing.abandon(io);
    try peer.accept(io);
    try peers.shakeHands(&peer, io, .zero);
    try peers.expectCommand(&peer, &.{ "SUBSCRIBE", "news" });
    try peer.send("-NOPERM User default has no permissions to access the 'news' channel\r\n");
    try testing.expectError(error.ServerError, subscribing.await(io));
    try testing.expect(d.isCode("NOPERM"));
    try testing.expectEqualStrings("NOPERM User default has no permissions to access the 'news' channel", d.message());
    // The client closed the connection: the peer reads its end.
    _ = try peer.readToEnd();
    try testing.expectEqual(@as(usize, 0), client.stats().subscribers);
}

const orders_subscribed: FakeServer.Reply = .subscribed(&.{"orders"});
const late_subscribed: FakeServer.Reply = .{ .delayed = .{ .after = .fromMilliseconds(400), .reply = &orders_subscribed } };

test "confirmations that come after the deadline of op are Timeout, and no subscriber is left" {
    try within5s(testing.io, lateConfirmation, .{testing.io});
}

fn lateConfirmation(io: Io) !void {
    var server: FakeServer = try .start(testing.allocator, io, &.{.expect(.{ "SUBSCRIBE", "orders" }, late_subscribed)});
    defer server.stop(io);
    var client: Client = undefined;
    try connected(io, &client, .{ .url = server.url() });
    defer client.deinit();
    var d: Diagnostics = .{};
    try testing.expectError(error.Timeout, client.subscribe(io, within(io, .fromMilliseconds(150)), .{ .channels = &.{"orders"}, .diagnostics = &d }));
    try testing.expectEqualStrings("the deadline passed before the server confirmed the subscription", d.message());
    try testing.expectEqual(@as(usize, 0), client.stats().subscribers);
}

test "no channels and no patterns, an idle_ping under 1 ms or too long, no connect and a closed client refuse at once, and nothing goes out" {
    try within5s(testing.io, refusedAtOnce, .{testing.io});
}

fn refusedAtOnce(io: Io) !void {
    var server: FakeServer = try .start(testing.allocator, io, &.{});
    defer server.stop(io);
    var client: Client = try .init(testing.allocator, io, .{ .url = server.url() });
    defer client.deinit();
    var d: Diagnostics = .{};
    try testing.expectError(error.Unavailable, client.subscribe(io, .of(.root), .{ .channels = &.{"orders"}, .diagnostics = &d }));
    try testing.expectEqualStrings("connect() has not succeeded", d.message());
    try client.connect(io, .root, null);
    try testing.expectError(error.InvalidArgument, client.subscribe(io, .of(.root), .{ .diagnostics = &d }));
    try testing.expectEqualStrings("redis.Client.subscribe: no channels and no patterns: give one or more", d.message());
    try testing.expectError(error.InvalidArgument, client.subscribe(io, .of(.root), .{ .channels = &.{"orders"}, .idle_ping = .fromMicroseconds(500), .diagnostics = &d }));
    try testing.expectEqualStrings("redis.Client.subscribe: .idle_ping is under 1 ms: give 1 ms or more", d.message());
    try testing.expectError(error.InvalidArgument, client.subscribe(io, .of(.root), .{ .channels = &.{"orders"}, .idle_ping = .fromSeconds(-1), .diagnostics = &d }));
    try testing.expectEqualStrings("redis.Client.subscribe: .idle_ping is under 1 ms: give 1 ms or more", d.message());
    try testing.expectError(error.InvalidArgument, client.subscribe(io, .of(.root), .{ .channels = &.{"orders"}, .idle_ping = .max, .diagnostics = &d }));
    try testing.expectEqualStrings("redis.Client.subscribe: .idle_ping is longer than 9223372036854775807 ms, the most the client counts", d.message());
    try testing.expectError(error.DeadlineExceeded, client.subscribe(io, within(io, .zero), .{ .channels = &.{"orders"}, .diagnostics = &d }));
    client.close(io);
    try testing.expectError(error.Closed, client.subscribe(io, .of(.root), .{ .channels = &.{"orders"}, .diagnostics = &d }));
    try testing.expectEqualStrings("the client is closed", d.message());
    try testing.expectEqual(@as(usize, 0), server.received(io));
}
