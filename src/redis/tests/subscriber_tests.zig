//! Tests of `redis.Client.subscribe` and `redis.Subscriber` against
//! `redis.testing.FakeServer` and `FakeServer.Peer` over loopback: the
//! subscription on a connection of its own, with the handshake of the
//! pool's, both commands in one write, and its refusals; the messages of
//! `next`, of channels and of patterns, binary and larger than the read
//! buffer, the PING of a silent connection, and how a subscriber ends: a
//! server that stops answering or closes, a message too large, a canceled
//! task; `close` from another task, also while the reading task holds a
//! message, which stays as it came, and the client's `close`. The waits of
//! `next` run on the `Io` of `windows_like_io.zig` too, which cannot time a
//! read and where a shutdown of a socket does not end the read that waits
//! on it. Every test runs under a time limit of 5 s.

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
const WindowsLike = @import("windows_like_io.zig").WindowsLike;
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
    defer sub.deinit();
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
    defer channels.deinit();
    var patterns = try client.subscribe(io, .of(.root), .{ .patterns = &.{"events.*"} });
    defer patterns.deinit();
    try testing.expectEqual(@as(usize, 2), server.received(io));
    try testing.expectEqual(@as(u32, 2), (try server.entry(io, 0)).connection);
    try testing.expectEqual(@as(u32, 3), (try server.entry(io, 1)).connection);
    try server.finish(io);
}

/// Expects `result` of a subscribe to be the error `expected`. A
/// subscriber that came instead is freed: the client must not go with a
/// subscriber left.
fn expectRefused(expected: redis.Error, result: redis.Error!redis.Subscriber) !void {
    if (result) |sub| {
        var left = sub;
        left.deinit();
        std.debug.print("expected error.{t}, found a subscriber\n", .{expected});
        return error.TestExpectedError;
    } else |err| try testing.expectEqual(expected, err);
}

/// `client.subscribe` from a task of its own.
fn subscribeTo(client: *Client, io: Io, options: redis.SubscribeOptions) redis.Error!redis.Subscriber {
    return client.subscribe(io, .of(.root), options);
}

/// A subscribe in a task of its own, which the test awaits once. If the
/// test fails first, `abandon` cancels it and frees the subscriber it may
/// have made: a client must not go with a subscriber left.
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
            left.deinit();
        } else |_| {}
    }
};

/// Accepts the client's first connection on `peer` and shakes hands on it,
/// while the client connects on `io`. The peer is on `std.testing.io`.
fn connectThrough(io: Io, peer: *Peer, client: *Client) !void {
    var connecting = try io.concurrent(Client.connect, .{ client, io, core.Context.root, null });
    defer connecting.cancel(io) catch {};
    try peer.accept(testing.io);
    try peers.shakeHands(peer, testing.io, .zero);
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
    defer sub.deinit();
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
    try expectRefused(error.ServerError, subscribing.await(io));
    try testing.expect(d.isCode("NOPERM"));
    try testing.expectEqualStrings("NOPERM User default has no permissions to access the 'news' channel", d.message());
    // The client closed the connection: the peer reads its end.
    _ = try peer.readToEnd();
    try testing.expectEqual(@as(usize, 0), client.stats().subscribers);
}

const orders_subscribed: FakeServer.Reply = .subscribed(&.{"orders"});
const late_subscribed: FakeServer.Reply = .{ .delayed = .{ .after = .fromSeconds(2), .reply = &orders_subscribed } };

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
    try expectRefused(error.Timeout, client.subscribe(io, within(io, .fromMilliseconds(300)), .{ .channels = &.{"orders"}, .diagnostics = &d }));
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
    try expectRefused(error.Unavailable, client.subscribe(io, .of(.root), .{ .channels = &.{"orders"}, .diagnostics = &d }));
    try testing.expectEqualStrings("connect() has not succeeded", d.message());
    try client.connect(io, .root, null);
    try expectRefused(error.InvalidArgument, client.subscribe(io, .of(.root), .{ .diagnostics = &d }));
    try testing.expectEqualStrings("redis.Client.subscribe: no channels and no patterns: give one or more", d.message());
    try expectRefused(error.InvalidArgument, client.subscribe(io, .of(.root), .{ .channels = &.{"orders"}, .idle_ping = .fromMicroseconds(500), .diagnostics = &d }));
    try testing.expectEqualStrings("redis.Client.subscribe: .idle_ping is under 1 ms: give 1 ms or more", d.message());
    try expectRefused(error.InvalidArgument, client.subscribe(io, .of(.root), .{ .channels = &.{"orders"}, .idle_ping = .fromSeconds(-1), .diagnostics = &d }));
    try testing.expectEqualStrings("redis.Client.subscribe: .idle_ping is under 1 ms: give 1 ms or more", d.message());
    try expectRefused(error.InvalidArgument, client.subscribe(io, .of(.root), .{ .channels = &.{"orders"}, .idle_ping = .max, .diagnostics = &d }));
    try testing.expectEqualStrings("redis.Client.subscribe: .idle_ping is longer than 9223372036854775807 ms, the most the client counts", d.message());
    try expectRefused(error.DeadlineExceeded, client.subscribe(io, within(io, .zero), .{ .channels = &.{"orders"}, .diagnostics = &d }));
    client.close(io);
    try expectRefused(error.Closed, client.subscribe(io, .of(.root), .{ .channels = &.{"orders"}, .diagnostics = &d }));
    try testing.expectEqualStrings("the client is closed", d.message());
    try testing.expectEqual(@as(usize, 0), server.received(io));
}

fn expectMessage(expected: redis.Subscriber.Message, got: ?redis.Subscriber.Message) !void {
    const message = got orelse return error.TestExpectedMessage;
    try testing.expectEqualStrings(expected.channel, message.channel);
    try testing.expectEqualStrings(expected.payload, message.payload);
    try testing.expectEqualDeep(expected.pattern, message.pattern);
}

/// `sub.next` from a task of its own.
fn nextOf(sub: *redis.Subscriber, io: Io) redis.Error!?redis.Subscriber.Message {
    return sub.next(io);
}

const Reading = Io.Future(redis.Error!?redis.Subscriber.Message);

/// Cancels a `next` of `nextOf` that the test left, if it did: before the
/// subscriber closes.
fn stopReading(reading: *Reading, io: Io) void {
    if (reading.cancel(io)) |_| {} else |_| {}
}

test "next gives the messages of channels and of patterns, a payload byte for byte, one larger than the read buffer whole, and skips pushes of other kinds" {
    try within5s(testing.io, messages, .{testing.io});
}

fn messages(io: Io) !void {
    // 1 MiB, against the 16 KiB of the connection's read buffer.
    const big = try testing.allocator.alloc(u8, 1024 * 1024);
    defer testing.allocator.free(big);
    for (big, 0..) |*b, i| b.* = @truncate(i *% 31);
    const big_message = [_]FakeServer.Reply{ .{ .string = "message" }, .{ .string = "orders" }, .{ .string = big } };
    const steps = [_]FakeServer.Step{
        .expect(.{ "SUBSCRIBE", "orders" }, .subscribed(&.{"orders"})),
        .expect(.{ "PSUBSCRIBE", "events.*" }, psubscribed),
        .send(.message("orders", "new")),
        .send(.{ .push = &.{ .{ .string = "pmessage" }, .{ .string = "events.*" }, .{ .string = "events.new" }, .{ .string = "x" } } }),
        .send(.{ .push = &.{ .{ .string = "invalidate" }, .{ .array = &.{.{ .string = "k" }} } } }),
        .send(.message("orders", "a\r\nb\x00c")),
        .send(.{ .push = &big_message }),
        .send(.message("orders", "after")),
    };
    var server: FakeServer = try .start(testing.allocator, io, &steps);
    defer server.stop(io);
    var client: Client = undefined;
    try connected(io, &client, .{ .url = server.url() });
    defer client.deinit();
    var sub = try client.subscribe(io, .of(.root), .{ .channels = &.{"orders"}, .patterns = &.{"events.*"} });
    defer sub.deinit();
    try expectMessage(.{ .channel = "orders", .payload = "new" }, try sub.next(io));
    try expectMessage(.{ .channel = "events.new", .payload = "x", .pattern = "events.*" }, try sub.next(io));
    try expectMessage(.{ .channel = "orders", .payload = "a\r\nb\x00c" }, try sub.next(io));
    const whole = (try sub.next(io)) orelse return error.TestExpectedMessage;
    try testing.expectEqualStrings("orders", whole.channel);
    try testing.expect(std.mem.eql(u8, big, whole.payload));
    try expectMessage(.{ .channel = "orders", .payload = "after" }, try sub.next(io));
    try server.finish(io);
}

test "a message that comes between the confirmations of SUBSCRIBE and PSUBSCRIBE is the first that next gives" {
    try within5s(testing.io, between, .{testing.io});
}

fn between(io: Io) !void {
    var server: FakeServer = try .start(testing.allocator, io, &.{
        .expect(.{ "SUBSCRIBE", "orders" }, .subscribed(&.{"orders"})),
        .send(.message("orders", "early")),
        .expect(.{ "PSUBSCRIBE", "events.*" }, psubscribed),
        .send(.message("orders", "later")),
    });
    defer server.stop(io);
    var client: Client = undefined;
    try connected(io, &client, .{ .url = server.url() });
    defer client.deinit();
    var sub = try client.subscribe(io, .of(.root), .{ .channels = &.{"orders"}, .patterns = &.{"events.*"} });
    defer sub.deinit();
    try expectMessage(.{ .channel = "orders", .payload = "early" }, try sub.next(io));
    try expectMessage(.{ .channel = "orders", .payload = "later" }, try sub.next(io));
    try server.finish(io);
}

/// The confirmation of `SUBSCRIBE orders` and the message `payload` of
/// `orders`, as a server writes them.
const orders_confirmation = ">3\r\n$9\r\nsubscribe\r\n$6\r\norders\r\n:1\r\n";

fn ordersMessage(comptime payload: []const u8) []const u8 {
    return std.fmt.comptimePrint(">3\r\n$7\r\nmessage\r\n$6\r\norders\r\n${d}\r\n{s}\r\n", .{ payload.len, payload });
}

/// A subscriber of `orders` with `idle_ping` on `peer`, which plays the
/// server: the client's first connection, then the subscriber's. The
/// client is on `io`, the peer on `std.testing.io`.
fn subscribeThrough(io: Io, peer: *Peer, client: *Client, idle_ping: Io.Duration) !redis.Subscriber {
    try connectThrough(io, peer, client);
    var subscribing: Subscribing = try .start(io, client, .{ .channels = &.{"orders"}, .idle_ping = idle_ping });
    defer subscribing.abandon(io);
    try peer.accept(testing.io);
    try peers.shakeHands(peer, testing.io, .zero);
    try peers.expectCommand(peer, &.{ "SUBSCRIBE", "orders" });
    try peer.send(orders_confirmation);
    return subscribing.await(io);
}

test "after idle_ping of silence the subscriber sends PING and takes its +PONG, and the messages go on, also where a read cannot be timed" {
    var windows: WindowsLike = undefined;
    for ([_]Io{ testing.io, windows.io() }) |io| try within5s(testing.io, pings, .{io});
}

/// The client on `io`, the peer on `std.testing.io`.
fn pings(io: Io) !void {
    var peer: Peer = try .listen(testing.io);
    defer peer.close(testing.io);
    var client: Client = try .init(testing.allocator, io, .{ .url = peer.url() });
    defer client.deinit();
    var sub = try subscribeThrough(io, &peer, &client, .fromMilliseconds(400));
    defer sub.deinit();

    const start = time.now(io);
    var reading = try io.concurrent(nextOf, .{ &sub, io });
    defer stopReading(&reading, io);
    try peers.expectCommand(&peer, &.{"PING"});
    try testing.expect(start.durationTo(time.now(io)).toMilliseconds() >= 390);
    try peer.send("+PONG\r\n" ++ comptime ordersMessage("first"));
    try expectMessage(.{ .channel = "orders", .payload = "first" }, try reading.await(io));

    // Silence twice more: a PING each time, its +PONG taken, then a message.
    reading = try io.concurrent(nextOf, .{ &sub, io });
    try peers.expectCommand(&peer, &.{"PING"});
    try peer.send("+PONG\r\n");
    try peers.expectCommand(&peer, &.{"PING"});
    try peer.send("+PONG\r\n" ++ comptime ordersMessage("second"));
    try expectMessage(.{ .channel = "orders", .payload = "second" }, try reading.await(io));
}

test "a server that does not answer PING makes next ConnectionLost within twice idle_ping, then Closed, and the subscriber's connection closes, also where a read cannot be timed" {
    var windows: WindowsLike = undefined;
    for ([_]Io{ testing.io, windows.io() }) |io| try within5s(testing.io, deaf, .{io});
}

fn deaf(io: Io) !void {
    var peer: Peer = try .listen(testing.io);
    defer peer.close(testing.io);
    var client: Client = try .init(testing.allocator, io, .{ .url = peer.url() });
    defer client.deinit();
    var sub = try subscribeThrough(io, &peer, &client, .fromMilliseconds(100));
    defer sub.deinit();

    const start = time.now(io);
    var reading = try io.concurrent(nextOf, .{ &sub, io });
    defer stopReading(&reading, io);
    try peers.expectCommand(&peer, &.{"PING"});
    try testing.expectError(error.ConnectionLost, reading.await(io));
    const took = start.durationTo(time.now(io)).toMilliseconds();
    try testing.expect(took >= 190 and took < 1000);
    try testing.expect(std.mem.endsWith(u8, sub.diagnostics().message(), " sent nothing within idle_ping (100 ms) after the subscriber's PING"));
    try testing.expectError(error.Closed, sub.next(io));
    try testing.expectEqualStrings("the subscriber lost its connection to an error before: close it, and subscribe again", sub.diagnostics().message());
    // The subscriber ended its connection: the peer reads to its end.
    _ = try peer.readToEnd();
}

test "a message whose rest comes 50 ms after its first half, within idle_ping, is one message, also where a read cannot be timed" {
    var windows: WindowsLike = undefined;
    for ([_]Io{ testing.io, windows.io() }) |io| try within5s(testing.io, halves, .{io});
}

fn halves(io: Io) !void {
    var peer: Peer = try .listen(testing.io);
    defer peer.close(testing.io);
    var client: Client = try .init(testing.allocator, io, .{ .url = peer.url() });
    defer client.deinit();
    // The rest must come within idle_ping of the subscriber's read, and a
    // loaded machine may run the peer's second send long after its 50 ms:
    // idle_ping is far longer than the pause.
    var sub = try subscribeThrough(io, &peer, &client, .fromSeconds(1));
    defer sub.deinit();

    var reading = try io.concurrent(nextOf, .{ &sub, io });
    defer stopReading(&reading, io);
    const whole = comptime ordersMessage("halves");
    try peer.send(whole[0 .. whole.len - 5]);
    try redis.testing.sleepAtLeast(testing.io, .fromMilliseconds(50));
    try peer.send(whole[whole.len - 5 ..]);
    try expectMessage(.{ .channel = "orders", .payload = "halves" }, try reading.await(io));
}

test "a server that closes the connection makes next ConnectionLost, whose text says a server closes a subscriber that falls behind; then Closed, and no SUBSCRIBE goes out again, also where the end of a stream reads as an error" {
    var windows: WindowsLike = undefined;
    for ([_]Io{ testing.io, windows.io() }) |io| try within5s(testing.io, closedByServer, .{io});
}

/// The client on `io`, the server on `std.testing.io`.
fn closedByServer(io: Io) !void {
    var server: FakeServer = try .start(testing.allocator, testing.io, &.{
        .expect(.{ "SUBSCRIBE", "orders" }, .subscribed(&.{"orders"})),
        .send(.message("orders", "last")),
        .send(.close_connection),
    });
    defer server.stop(testing.io);
    var client: Client = undefined;
    try connected(io, &client, .{ .url = server.url() });
    defer client.deinit();
    var sub = try client.subscribe(io, .of(.root), .{ .channels = &.{"orders"} });
    defer sub.deinit();
    try expectMessage(.{ .channel = "orders", .payload = "last" }, try sub.next(io));
    try testing.expectError(error.ConnectionLost, sub.next(io));
    try testing.expect(std.mem.indexOf(u8, sub.diagnostics().message(), "closed the connection, as a server does to a subscriber that falls behind its messages") != null);
    try testing.expectError(error.Closed, sub.next(io));
    try testing.expectEqual(@as(usize, 1), server.count(testing.io, "SUBSCRIBE"));
    try server.finish(testing.io);
}

test "a message larger than max_reply_bytes is ReplyTooLarge, and a reply that no PING asked for a ProtocolViolation; next is Closed after either" {
    try within5s(testing.io, broken, .{testing.io});
}

fn broken(io: Io) !void {
    const payload = try testing.allocator.alloc(u8, 70 * 1024);
    defer testing.allocator.free(payload);
    @memset(payload, 'x');
    const too_large = [_]FakeServer.Reply{ .{ .string = "message" }, .{ .string = "orders" }, .{ .string = payload } };
    const steps = [_]FakeServer.Step{
        .expect(.{ "SUBSCRIBE", "orders" }, .subscribed(&.{"orders"})),
        .send(.{ .push = &too_large }),
        .expect(.{ "SUBSCRIBE", "news" }, .subscribed(&.{"news"})),
        .send(.ok),
    };
    var server: FakeServer = try .start(testing.allocator, io, &steps);
    defer server.stop(io);
    var client: Client = undefined;
    try connected(io, &client, .{ .url = server.url(), .max_reply_bytes = 64 * 1024 });
    defer client.deinit();

    var orders = try client.subscribe(io, .of(.root), .{ .channels = &.{"orders"} });
    defer orders.deinit();
    try testing.expectError(error.ReplyTooLarge, orders.next(io));
    try testing.expectEqualStrings("a message is larger than max_reply_bytes (65536) or nests deeper than 64 levels", orders.diagnostics().message());
    try testing.expectError(error.Closed, orders.next(io));

    var news = try client.subscribe(io, .of(.root), .{ .channels = &.{"news"} });
    defer news.deinit();
    try testing.expectError(error.ProtocolViolation, news.next(io));
    try testing.expectEqualStrings("the server sent a reply that the subscriber did not ask for", news.diagnostics().message());
    try testing.expectError(error.Closed, news.next(io));
    try testing.expectEqual(@as(usize, 2), server.count(io, "SUBSCRIBE"));
    try server.finish(io);
}

/// The memory of `child`, but no block larger than `limit`.
const Capped = struct {
    child: std.mem.Allocator,
    limit: usize,

    fn allocator(c: *Capped) std.mem.Allocator {
        return .{ .ptr = c, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const c: *Capped = @ptrCast(@alignCast(context));
        if (len > c.limit) return null;
        return c.child.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const c: *Capped = @ptrCast(@alignCast(context));
        if (new_len > c.limit) return false;
        return c.child.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const c: *Capped = @ptrCast(@alignCast(context));
        if (new_len > c.limit) return null;
        return c.child.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const c: *Capped = @ptrCast(@alignCast(context));
        c.child.rawFree(memory, alignment, ret_addr);
    }
};

test "a message that finds no memory is OutOfMemory of next, then Closed; the pool and its connection are untouched, and the next call goes on" {
    try within5s(testing.io, messageOutOfMemory, .{testing.io});
}

fn messageOutOfMemory(io: Io) !void {
    const payload = try testing.allocator.alloc(u8, 256 * 1024);
    defer testing.allocator.free(payload);
    @memset(payload, 'x');
    const big = [_]FakeServer.Reply{ .{ .string = "message" }, .{ .string = "orders" }, .{ .string = payload } };
    const steps = [_]FakeServer.Step{
        .expect(.{ "SUBSCRIBE", "orders" }, .subscribed(&.{"orders"})),
        .send(.{ .push = &big }),
        .expect(.{ "GET", "k" }, .{ .integer = 8 }),
    };
    var server: FakeServer = try .start(testing.allocator, io, &steps);
    defer server.stop(io);
    // Room for a connection, not for the message.
    var capped: Capped = .{ .child = testing.allocator, .limit = 128 * 1024 };
    var client: Client = try .init(capped.allocator(), io, .{ .url = server.url() });
    defer client.deinit();
    try client.connect(io, .root, null);
    var sub = try client.subscribe(io, .of(.root), .{ .channels = &.{"orders"} });
    defer sub.deinit();
    try testing.expectError(error.OutOfMemory, sub.next(io));
    try testing.expectEqualStrings("no memory was left for a message", sub.diagnostics().message());
    try testing.expectError(error.Closed, sub.next(io));
    const stats = client.stats();
    try testing.expectEqual(@as(usize, 1), stats.connections);
    try testing.expectEqual(@as(u64, 0), stats.clears);
    try testing.expectEqual(@as(?i64, 8), try client.run(io, .of(.root), redis.cmd.raw(?i64, .{ "GET", "k" }), .{}));
    // The pool's connection took the call: the one connect opened.
    try testing.expectEqual(@as(u32, 1), (try server.entry(io, 1)).connection);
    try server.finish(io);
}

test "a task canceled while next waits is Interrupted and keeps its cancelation, and next is Closed after it, also where a read cannot be timed" {
    var windows: WindowsLike = undefined;
    for ([_]Io{ testing.io, windows.io() }) |io| try within5s(testing.io, canceled, .{io});
}

fn nextCanceled(sub: *redis.Subscriber, io: Io) !void {
    try testing.expectError(error.Interrupted, sub.next(io));
    try testing.expectError(error.Canceled, io.checkCancel());
}

/// The client on `io`, the server on `std.testing.io`.
fn canceled(io: Io) !void {
    var server: FakeServer = try .start(testing.allocator, testing.io, &.{.expect(.{ "SUBSCRIBE", "orders" }, .subscribed(&.{"orders"}))});
    defer server.stop(testing.io);
    var client: Client = undefined;
    try connected(io, &client, .{ .url = server.url() });
    defer client.deinit();
    var sub = try client.subscribe(io, .of(.root), .{ .channels = &.{"orders"} });
    defer sub.deinit();
    var reading = try io.concurrent(nextCanceled, .{ &sub, io });
    defer reading.cancel(io) catch {};
    // Long enough for next to wait on the socket.
    try redis.testing.sleepAtLeast(testing.io, .fromMilliseconds(50));
    try reading.cancel(io);
    try testing.expectError(error.Closed, sub.next(io));
    try server.finish(testing.io);
}

test "close from another task while next waits: next returns null, close returns once it has, and a second close at once; also where a shutdown does not end a read" {
    var windows: WindowsLike = undefined;
    for ([_]Io{ testing.io, windows.io() }) |io| try within5s(testing.io, closeWhileWaiting, .{io});
}

/// The client on `io`, the server on `std.testing.io`.
fn closeWhileWaiting(io: Io) !void {
    var server: FakeServer = try .start(testing.allocator, testing.io, &.{.expect(.{ "SUBSCRIBE", "orders" }, .subscribed(&.{"orders"}))});
    defer server.stop(testing.io);
    var client: Client = undefined;
    try connected(io, &client, .{ .url = server.url() });
    defer client.deinit();
    // An idle_ping far beyond what the test waits: the cut wakes next, not
    // its PING.
    var sub = try client.subscribe(io, .of(.root), .{ .channels = &.{"orders"}, .idle_ping = .fromSeconds(3) });
    defer sub.deinit();
    var reading = try io.concurrent(nextOf, .{ &sub, io });
    defer stopReading(&reading, io);
    // Long enough for next to wait on the socket.
    try redis.testing.sleepAtLeast(testing.io, .fromMilliseconds(100));
    const start = time.now(io);
    sub.close(io);
    try testing.expect(start.durationTo(time.now(io)).toMilliseconds() < 1000);
    try testing.expectEqual(@as(?redis.Subscriber.Message, null), try reading.await(io));
    try testing.expectEqual(@as(usize, 0), client.stats().subscribers);
    sub.close(io);
    try testing.expectEqual(@as(?redis.Subscriber.Message, null), try sub.next(io));
    try server.finish(testing.io);
}

/// An `Io` for the end of a `next` that `close` cuts: `std.testing.io`, with
/// two holds, each once after `arm`. The read that the cut ends returns
/// 200 ms late, so that `close` waits for `next` on its lock; the wake of
/// that lock returns to `next` 300 ms late, so that `close` returns while
/// `next` has the rest of its end still to run.
const SlowEnd = struct {
    vtable: Io.VTable,

    var lock: std.atomic.Value(usize) = .init(0);
    var hold_read: std.atomic.Value(bool) = .init(false);
    var hold_wake: std.atomic.Value(bool) = .init(false);

    fn io(s: *SlowEnd) Io {
        s.vtable = testing.io.vtable.*;
        s.vtable.batchAwaitConcurrent = batchAwaitConcurrent;
        s.vtable.futexWake = futexWake;
        return .{ .userdata = testing.io.userdata, .vtable = &s.vtable };
    }

    fn arm(mutex: *const Io.Mutex) void {
        lock.store(@intFromPtr(&mutex.state.raw), .release);
        hold_read.store(true, .release);
        hold_wake.store(true, .release);
    }

    fn batchAwaitConcurrent(userdata: ?*anyopaque, batch: *Io.Batch, timeout: Io.Timeout) Io.Batch.AwaitConcurrentError!void {
        defer if (hold_read.swap(false, .acq_rel)) holdOn(200);
        return testing.io.vtable.batchAwaitConcurrent(userdata, batch, timeout);
    }

    fn futexWake(userdata: ?*anyopaque, ptr: *const u32, max_waiters: u32) void {
        testing.io.vtable.futexWake(userdata, ptr, max_waiters);
        if (@intFromPtr(ptr) == lock.load(.acquire) and hold_wake.swap(false, .acq_rel)) holdOn(300);
    }

    fn holdOn(ms: i64) void {
        testing.io.sleep(.fromMilliseconds(ms), .awake) catch {};
    }
};

test "close from another task returns once next is done with the subscriber: nothing of next writes to it after, so it may go once the reading task is awaited" {
    var slow: SlowEnd = undefined;
    try within5s(testing.io, endOfNext, .{slow.io()});
}

/// The client on `io`, the server on `std.testing.io`.
fn endOfNext(io: Io) !void {
    var server: FakeServer = try .start(testing.allocator, testing.io, &.{.expect(.{ "SUBSCRIBE", "orders" }, .subscribed(&.{"orders"}))});
    defer server.stop(testing.io);
    var client: Client = undefined;
    try connected(io, &client, .{ .url = server.url() });
    defer client.deinit();
    var sub = try client.subscribe(io, .of(.root), .{ .channels = &.{"orders"}, .idle_ping = .fromSeconds(3) });
    defer sub.deinit();
    var reading = try io.concurrent(nextOf, .{ &sub, io });
    defer stopReading(&reading, io);
    // Long enough for next to wait on the socket.
    try redis.testing.sleepAtLeast(testing.io, .fromMilliseconds(100));
    SlowEnd.arm(&sub.running);
    sub.close(io);
    // A subscriber that went at once: nothing of next may write to it now.
    const kept = sub;
    const bytes = std.mem.asBytes(&sub);
    @memset(bytes, 0xAA);
    const result = reading.await(io);
    const untouched = std.mem.allEqual(u8, bytes, 0xAA);
    sub = kept;
    try testing.expectEqual(@as(?redis.Subscriber.Message, null), try result);
    try testing.expect(untouched);
    try server.finish(testing.io);
}

/// An allocator for the client that keeps what it frees: a freed block is
/// filled with 0xAA and kept until `deinit`, so that a read after a free
/// sees 0xAA, where it would crash with the block returned to the system.
const Quarantine = struct {
    child: std.mem.Allocator,
    /// For the lock: tasks of the client free from other threads.
    io: Io,
    mutex: Io.Mutex = .init,
    kept: std.ArrayList(Block) = .empty,

    const Block = struct { memory: []u8, alignment: std.mem.Alignment };

    fn allocator(q: *Quarantine) std.mem.Allocator {
        return .{ .ptr = q, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const q: *Quarantine = @ptrCast(@alignCast(context));
        return q.child.rawAlloc(len, alignment, ret_addr);
    }

    /// No block changes in place: one that grows or shrinks moves, and its
    /// old place goes through `free`.
    fn resize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
        return false;
    }

    fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
        return null;
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const q: *Quarantine = @ptrCast(@alignCast(context));
        @memset(memory, 0xAA);
        q.mutex.lockUncancelable(q.io);
        defer q.mutex.unlock(q.io);
        q.kept.append(q.child, .{ .memory = memory, .alignment = alignment }) catch q.child.rawFree(memory, alignment, ret_addr);
    }

    fn deinit(q: *Quarantine) void {
        for (q.kept.items) |block| q.child.rawFree(block.memory, block.alignment, @returnAddress());
        q.kept.deinit(q.child);
    }
};

/// Takes the next message of `sub`, sets `holding`, and once `go` is set,
/// checks that the message is still as it came, and that the `next` after
/// it returns null.
fn holdMessage(sub: *redis.Subscriber, io: Io, holding: *Io.Event, go: *Io.Event, expected: redis.Subscriber.Message) !void {
    const message = (try sub.next(io)) orelse return error.TestExpectedMessage;
    holding.set(io);
    try go.wait(io);
    try expectMessage(expected, message);
    try testing.expectEqual(@as(?redis.Subscriber.Message, null), try sub.next(io));
}

/// `steps` give the subscriber of `options` one message, `expected`, which
/// the reading task holds while this task closes the subscriber. The
/// client's memory is a quarantine: had close freed the message, it would
/// read as 0xAA.
fn closeWhileHeld(io: Io, steps: []const FakeServer.Step, options: redis.SubscribeOptions, expected: redis.Subscriber.Message) !void {
    var quarantine: Quarantine = .{ .child = testing.allocator, .io = io };
    defer quarantine.deinit();
    var server: FakeServer = try .start(testing.allocator, io, steps);
    defer server.stop(io);
    var client: Client = try .init(quarantine.allocator(), io, .{ .url = server.url() });
    defer client.deinit();
    try client.connect(io, .root, null);
    var sub = try client.subscribe(io, .of(.root), options);
    defer sub.deinit();
    var holding: Io.Event = .unset;
    var go: Io.Event = .unset;
    var reading = try io.concurrent(holdMessage, .{ &sub, io, &holding, &go, expected });
    defer reading.cancel(io) catch {};
    try holding.wait(io);
    sub.close(io);
    go.set(io);
    try reading.await(io);
    try server.finish(io);
}

test "a message that the reading task holds while another task closes the subscriber stays as it came until its next next, which returns null" {
    try within5s(testing.io, heldMessage, .{testing.io});
}

fn heldMessage(io: Io) !void {
    try closeWhileHeld(io, &.{
        .expect(.{ "SUBSCRIBE", "orders" }, .subscribed(&.{"orders"})),
        .send(.message("orders", "order 1001 is packed")),
    }, .{ .channels = &.{"orders"} }, .{ .channel = "orders", .payload = "order 1001 is packed" });
}

test "a message that came between the confirmations, held by the reading task while another task closes the subscriber, stays as it came too" {
    try within5s(testing.io, heldEarlyMessage, .{testing.io});
}

fn heldEarlyMessage(io: Io) !void {
    try closeWhileHeld(io, &.{
        .expect(.{ "SUBSCRIBE", "orders" }, .subscribed(&.{"orders"})),
        .send(.message("orders", "early")),
        .expect(.{ "PSUBSCRIBE", "events.*" }, psubscribed),
    }, .{ .channels = &.{"orders"}, .patterns = &.{"events.*"} }, .{ .channel = "orders", .payload = "early" });
}

test "the client's close ends every subscriber: next returns null, stats count each until its own close, and subscribe is Closed" {
    try within5s(testing.io, clientCloses, .{testing.io});
}

fn clientCloses(io: Io) !void {
    var server: FakeServer = try .start(testing.allocator, io, &.{
        .expect(.{ "SUBSCRIBE", "orders" }, .subscribed(&.{"orders"})),
        .expect(.{ "SUBSCRIBE", "news" }, .subscribed(&.{"news"})),
    });
    defer server.stop(io);
    var client: Client = undefined;
    try connected(io, &client, .{ .url = server.url() });
    defer client.deinit();
    var orders = try client.subscribe(io, .of(.root), .{ .channels = &.{"orders"} });
    defer orders.deinit();
    var news = try client.subscribe(io, .of(.root), .{ .channels = &.{"news"} });
    defer news.deinit();
    var reading = try io.concurrent(nextOf, .{ &orders, io });
    defer stopReading(&reading, io);
    try redis.testing.sleepAtLeast(io, .fromMilliseconds(100));
    const start = time.now(io);
    client.close(io);
    try testing.expect(start.durationTo(time.now(io)).toMilliseconds() < 1000);
    try testing.expectEqual(@as(?redis.Subscriber.Message, null), try reading.await(io));
    try testing.expectEqual(@as(?redis.Subscriber.Message, null), try news.next(io));
    // They count until their own close, and their memory is theirs until
    // their deinit.
    try testing.expectEqual(@as(usize, 2), client.stats().subscribers);
    orders.close(io);
    news.close(io);
    try testing.expectEqual(@as(usize, 0), client.stats().subscribers);
    var d: Diagnostics = .{};
    try expectRefused(error.Closed, client.subscribe(io, .of(.root), .{ .channels = &.{"orders"}, .diagnostics = &d }));
    try server.finish(io);
}

const late_news: FakeServer.Reply = .{ .delayed = .{ .after = .fromSeconds(2), .reply = &orders_subscribed } };

test "the client's close ends a subscribe that waits for its confirmations: Closed, at once" {
    try within5s(testing.io, closeWhileSubscribing, .{testing.io});
}

fn closeWhileSubscribing(io: Io) !void {
    var server: FakeServer = try .start(testing.allocator, io, &.{.expect(.{ "SUBSCRIBE", "orders" }, late_news)});
    defer server.stop(io);
    var client: Client = undefined;
    try connected(io, &client, .{ .url = server.url() });
    defer client.deinit();
    var d: Diagnostics = .{};
    var subscribing: Subscribing = try .start(io, &client, .{ .channels = &.{"orders"}, .diagnostics = &d });
    defer subscribing.abandon(io);
    const give_up: core.Deadline = .after(time.now(io), .fromSeconds(4));
    while (server.received(io) == 0) {
        if (time.expired(io, give_up)) return error.TestTimedOut;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    const start = time.now(io);
    client.close(io);
    try expectRefused(error.Closed, subscribing.await(io));
    try testing.expect(start.durationTo(time.now(io)).toMilliseconds() < 1000);
    try testing.expectEqualStrings("the client was closed while it subscribed", d.message());
    try testing.expectEqual(@as(usize, 0), client.stats().subscribers);
}
