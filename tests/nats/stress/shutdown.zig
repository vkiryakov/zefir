//! Stopping a client while thousands of tasks wait in it: in `next()`,
//! `request()`, `flush()`, a publish waiting for room, and `nextEvent()`.
//! `close()` and a `drain()` that runs out of time must end every wait at
//! once, and leave nothing behind.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const nats = @import("nats");
const e2e = @import("e2e");
const stress = @import("root.zig");

const subscriptions = 200;
const requests = 1000;
const flushes = 100;
const publishers = 20;

/// How the waits ended, by kind.
const Outcomes = struct {
    /// Waits that ended with ConnectionClosed.
    closed: std.atomic.Value(u32) = .init(0),
    /// Waits that ended any other way.
    other: std.atomic.Value(u32) = .init(0),
    /// Tasks that are done.
    done: std.atomic.Value(u32) = .init(0),

    fn record(o: *Outcomes, err: anyerror) void {
        if (err == error.ConnectionClosed) {
            _ = o.closed.fetchAdd(1, .monotonic);
        } else if (o.other.fetchAdd(1, .monotonic) == 0) {
            std.debug.print("  a wait ended with {t}\n", .{err});
        }
    }
};

fn nextMessage(sub: *nats.Subscription, outcomes: *Outcomes) Io.Cancelable!void {
    defer _ = outcomes.done.fetchAdd(1, .monotonic);
    if (sub.next(.{})) |got| {
        if (got) |msg| {
            var m = msg;
            m.deinit();
        }
        outcomes.record(error.TestUnexpectedMessage);
    } else |err| outcomes.record(err);
}

fn request(client: *nats.Client, outcomes: *Outcomes) Io.Cancelable!void {
    defer _ = outcomes.done.fetchAdd(1, .monotonic);
    if (client.request("stress.stop.request", "?", .{ .timeout = .{ .duration = .{ .raw = .fromSeconds(60), .clock = .awake } } })) |reply| {
        var r = reply;
        r.deinit();
        outcomes.record(error.TestUnexpectedReply);
    } else |err| outcomes.record(err);
}

fn flush(client: *nats.Client, outcomes: *Outcomes) Io.Cancelable!void {
    defer _ = outcomes.done.fetchAdd(1, .monotonic);
    if (client.flush(.{ .timeout = .{ .duration = .{ .raw = .fromSeconds(60), .clock = .awake } } })) |_| {
        outcomes.record(error.TestUnexpectedPong);
    } else |err| outcomes.record(err);
}

/// Publishes until a publish fails; counts the ones that went in.
fn publish(client: *nats.Client, payload: []const u8, published: *std.atomic.Value(u32), outcomes: *Outcomes) Io.Cancelable!void {
    defer _ = outcomes.done.fetchAdd(1, .monotonic);
    while (true) {
        client.publish("stress.stop.publish", payload) catch |err| return outcomes.record(err);
        _ = published.fetchAdd(1, .monotonic);
    }
}

/// Takes events until the stream ends; it must end with null.
fn events(client: *nats.Client, outcomes: *Outcomes) Io.Cancelable!void {
    defer _ = outcomes.done.fetchAdd(1, .monotonic);
    while (true) {
        const event = client.nextEvent(.{}) catch |err| return outcomes.record(err);
        if (event == null) return outcomes.record(error.ConnectionClosed);
    }
}

/// Waits until a task waits in `next()` of every subscription of `subs`
/// and every request waits for its reply, for 20 s at most.
fn awaitWaiting(io: Io, client: *nats.Client, subs: []const *nats.Subscription) !void {
    const began = Io.Clock.awake.now(io);
    while (true) {
        const all_receiving = for (subs) |sub| {
            if (!sub.messages.isReceiving(io)) break false;
        } else true;
        if (all_receiving and client.inbox.awaitingCount(io) == requests) return;
        if (stress.elapsedSince(io, began).toSeconds() >= 20) return error.TestNeverWaiting;
        try io.sleep(.fromMilliseconds(5), .awake);
    }
}

const Stop = enum { close, drain };

fn stopWhileWaiting(io: Io, how: Stop) !void {
    var client: nats.Client = try .init(testing.allocator, io, .{
        .servers = &.{e2e.servers.stall},
        .name = "stress-stop",
        .limits = .{ .outbound_bytes = 64 * 1024 },
    });
    defer client.deinit();
    try client.connect();
    // Interest in the requests, so the server does not answer "no
    // responders"; no one answers them.
    const sink = try client.subscribe("stress.stop.request", .{});
    defer sink.deinit();
    var subs: [subscriptions]*nats.Subscription = undefined;
    var subscribed: usize = 0;
    defer for (subs[0..subscribed]) |sub| sub.deinit();
    for (&subs, 0..) |*sub, i| {
        var buffer: [32]u8 = undefined;
        sub.* = try client.subscribe(try std.fmt.bufPrint(&buffer, "stress.stop.sub.{d}", .{i}), .{});
        subscribed += 1;
    }
    try client.flush(.{});

    // Before the group: the publishers still use it until the group is
    // canceled, which on a failure comes after the errdefers below.
    const payload = try testing.allocator.alloc(u8, 256 * 1024);
    defer testing.allocator.free(payload);
    @memset(payload, 'p');

    var outcomes: Outcomes = .{};
    var group: Io.Group = .init;
    // Normally every task is done before this runs.
    defer group.cancel(io);
    for (subs) |sub| try group.concurrent(io, nextMessage, .{ sub, &outcomes });
    for (0..requests) |_| try group.concurrent(io, request, .{ &client, &outcomes });
    try group.concurrent(io, events, .{ &client, &outcomes });
    try awaitWaiting(io, &client, &subs);

    // The server stops reading and answering: PINGs wait for their PONG,
    // and publishes for room.
    try e2e.docker(&.{ "pause", e2e.servers.stall_container });
    errdefer e2e.unpause(e2e.servers.stall_container) catch {};
    for (0..flushes) |_| try group.concurrent(io, flush, .{ &client, &outcomes });
    var published: std.atomic.Value(u32) = .init(0);
    for (0..publishers) |_| try group.concurrent(io, publish, .{ &client, payload, &published, &outcomes });
    // Stuck: every publisher waits for room, and none went in for a while.
    var last = published.load(.monotonic);
    var still_since = Io.Clock.awake.now(io);
    const began = Io.Clock.awake.now(io);
    while (true) {
        try io.sleep(.fromMilliseconds(20), .awake);
        const now = published.load(.monotonic);
        if (now != last or client.outbound.roomWaiters(io) < publishers) {
            last = now;
            still_since = Io.Clock.awake.now(io);
        } else if (stress.elapsedSince(io, still_since).toMilliseconds() >= 300) {
            break;
        }
        if (stress.elapsedSince(io, began).toSeconds() >= 30) return error.TestPublishesNeverWaited;
    }

    const waiting = subscriptions + requests + 1 + flushes + publishers;
    const stopping = Io.Clock.awake.now(io);
    switch (how) {
        .close => client.close(),
        // The server never answers the drain's PING: it runs out of time
        // and closes the client.
        .drain => try testing.expectError(error.Timeout, client.drain(.{ .timeout = .{ .duration = .{ .raw = .fromMilliseconds(200), .clock = .awake } } })),
    }
    while (outcomes.done.load(.monotonic) < waiting) {
        if (stress.elapsedSince(io, stopping).toSeconds() >= 10) {
            // A wait that never ends: cleaning up would wait for it too.
            std.debug.print("  {d} of {d} waits still going 10 s after the stop\n", .{ waiting - outcomes.done.load(.monotonic), waiting });
            // Exiting skips the errdefers: leave the server running for
            // what comes next.
            e2e.unpause(e2e.servers.stall_container) catch {};
            std.process.exit(1);
        }
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    const took = stress.elapsedSince(io, stopping);
    try group.await(io);
    std.debug.print("  {t}: {d} waits ended in {d} ms\n", .{ how, waiting, took.toMilliseconds() });
    try testing.expectEqual(0, outcomes.other.load(.monotonic));
    try testing.expectEqual(waiting, outcomes.closed.load(.monotonic));
    // A second at most, after the 200 ms the drain had.
    const limit_ms: i64 = if (how == .drain) 1200 else 1000;
    try testing.expect(took.toMilliseconds() < limit_ms);
    // As it was, for the tests after this one.
    try e2e.unpause(e2e.servers.stall_container);
}

fn stopRounds(io: Io) !void {
    for ([_]Stop{ .close, .drain, .close }) |how| try stopWhileWaiting(io, how);
}

test "close() and a drain() out of time end 1,321 waits at once, and leave nothing behind" {
    try stress.onZio(stopRounds);
}
