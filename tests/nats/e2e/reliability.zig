//! Reconnect, failover, lame duck, refused credentials, drain and
//! retry_initial_connect on live servers. Each test that stops, pauses,
//! signals or reconfigures a server works on a server of its own and puts
//! it back as it was before it ends.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const nats = @import("nats");
const e2e = @import("root.zig");

fn duration(milliseconds: i64) Io.Timeout {
    return .{ .duration = .{ .raw = .fromMilliseconds(milliseconds), .clock = .awake } };
}

const within_five_seconds: nats.ReceiveOptions = .{ .timeout = duration(5000) };
const briefly: nats.ReceiveOptions = .{ .timeout = duration(100) };

/// Reconnect attempts close together, so the tests do not wait long.
const quick_reconnect: nats.ReconnectOptions = .{ .min_delay = .fromMilliseconds(100), .max_delay = .fromMilliseconds(500) };

fn elapsedSince(io: Io, start: Io.Timestamp) Io.Duration {
    return start.durationTo(Io.Clock.awake.now(io));
}

fn expectMessage(sub: *nats.Subscription, subject: []const u8, payload: []const u8) !void {
    var msg = (try sub.next(within_five_seconds)) orelse return error.TestNoMessage;
    defer msg.deinit();
    try testing.expectEqualStrings(subject, msg.subject);
    try testing.expectEqualStrings(payload, msg.payload);
}

/// Takes events until one is a `tag` one, and returns it; fails after
/// `seconds`.
fn awaitEvent(client: *nats.Client, tag: std.meta.Tag(nats.Event), seconds: i64) !nats.Event {
    const io = client.io;
    const start = Io.Clock.awake.now(io);
    while (elapsedSince(io, start).toSeconds() < seconds) {
        const next = client.nextEvent(.{ .timeout = duration(100) }) catch |err| switch (err) {
            error.Timeout => continue,
            else => |e| return e,
        };
        const event = next orelse return error.TestClientClosed;
        if (event == tag) return event;
    }
    return error.TestNoEvent;
}

/// Waits until `client` is in `expected`, for `seconds` at most.
fn awaitState(client: *nats.Client, expected: nats.State, seconds: i64) !void {
    const io = client.io;
    const start = Io.Clock.awake.now(io);
    while (client.state() != expected) {
        if (elapsedSince(io, start).toSeconds() >= seconds) return error.TestStateNeverReached;
        try io.sleep(.fromMilliseconds(10), .awake);
    }
}

/// Publishes to `subject` from `publisher` until `sub` gets a message, for
/// 10 s at most: interest moves between cluster nodes a moment after a SUB.
fn publishUntilReceived(publisher: *nats.Client, subject: []const u8, sub: *nats.Subscription) !void {
    const io = publisher.io;
    const start = Io.Clock.awake.now(io);
    while (elapsedSince(io, start).toSeconds() < 10) {
        try publisher.publish(subject, "ping");
        try publisher.flush(.{});
        var msg = (sub.next(briefly) catch |err| switch (err) {
            error.Timeout => continue,
            else => |e| return e,
        }) orelse return error.TestSubscriptionEnded;
        msg.deinit();
        return;
    }
    return error.TestNeverReceived;
}

fn serverRestart(io: Io) !void {
    var client: nats.Client = try .init(testing.allocator, io, .{
        .servers = &.{e2e.servers.restart},
        .name = "e2e-restart",
        .connect_timeout = .fromSeconds(1),
        .reconnect = quick_reconnect,
    });
    defer client.deinit();
    try client.connect();
    var responder: nats.Client = try .init(testing.allocator, io, .{ .servers = &.{e2e.servers.restart}, .reconnect = quick_reconnect });
    defer responder.deinit();
    try responder.connect();
    const service = try responder.subscribe("e2e.restart.svc", .{});
    defer service.deinit();
    try responder.flush(.{});
    var answering = try io.concurrent(answerAll, .{ &responder, service });
    defer answering.cancel(io) catch {};

    const all = try client.subscribe("e2e.restart.all.>", .{});
    defer all.deinit();
    const five = try client.subscribe("e2e.restart.five", .{ .max_messages = 5 });
    defer five.deinit();
    try client.flush(.{});
    try client.publish("e2e.restart.five", "1");
    try client.publish("e2e.restart.five", "2");
    try expectMessage(five, "e2e.restart.five", "1");
    try expectMessage(five, "e2e.restart.five", "2");
    var reply = try client.request("e2e.restart.svc", "before", .{ .timeout = duration(5000) });
    reply.deinit();

    // The server goes down. Publishes meanwhile wait for the next
    // connection.
    try e2e.docker(&.{ "stop", e2e.servers.restart_container });
    errdefer e2e.start(e2e.servers.restart_container) catch {};
    _ = try awaitEvent(&client, .disconnected, 10);
    try testing.expectEqual(.reconnecting, client.state());
    try client.publish("e2e.restart.all.buffered", "1");
    try client.publish("e2e.restart.all.buffered", "2");
    try client.publish("e2e.restart.all.buffered", "3");
    try testing.expectError(error.Disconnected, client.flush(.{}));

    try e2e.start(e2e.servers.restart_container);
    _ = try awaitEvent(&client, .reconnected, 10);
    // The subscriptions came back before the buffered publishes went out.
    try expectMessage(all, "e2e.restart.all.buffered", "1");
    try expectMessage(all, "e2e.restart.all.buffered", "2");
    try expectMessage(all, "e2e.restart.all.buffered", "3");
    // Three of five are left for `five`.
    for (3..9) |i| {
        var buffer: [4]u8 = undefined;
        try client.publish("e2e.restart.five", try std.fmt.bufPrint(&buffer, "{d}", .{i}));
    }
    try client.flush(.{});
    try expectMessage(five, "e2e.restart.five", "3");
    try expectMessage(five, "e2e.restart.five", "4");
    try expectMessage(five, "e2e.restart.five", "5");
    try testing.expect(try five.next(within_five_seconds) == null);
    // The inbox and the responder's subscription are back too.
    try awaitState(&responder, .connected, 10);
    try responder.flush(.{});
    var again = try client.request("e2e.restart.svc", "after", .{ .timeout = duration(5000) });
    defer again.deinit();
    try testing.expectEqualStrings("after", again.payload);
    const stats = client.stats();
    try testing.expectEqual(1, stats.reconnects);
    try testing.expectEqual(0, stats.dropped_messages);
}

/// Answers every request on `sub` with its own payload.
fn answerAll(client: *nats.Client, sub: *nats.Subscription) anyerror!void {
    while (true) {
        var msg = (try sub.next(.{})) orelse return;
        defer msg.deinit();
        client.respond(&msg, msg.payload) catch |err| switch (err) {
            // The server is down for a while.
            error.Disconnected, error.BufferFull => {},
            else => |e| return e,
        };
    }
}

test "a server restart: subscriptions, the inbox and the publishes made meanwhile come back" {
    try e2e.onZio(serverRestart);
}

fn clusterFailover(io: Io) !void {
    var client: nats.Client = try .init(testing.allocator, io, .{
        // Only node a: the others come from its INFO.
        .servers = &.{e2e.servers.cluster[0]},
        .connect_timeout = .fromSeconds(1),
        .reconnect = quick_reconnect,
    });
    defer client.deinit();
    try client.connect();
    var buffer: [8]nats.ServerAddress = undefined;
    const announced = client.discoveredServers(&buffer);
    try testing.expectEqual(2, announced.len);
    for (announced) |server| try testing.expect(server.port == 14227 or server.port == 14228);

    var publisher: nats.Client = try .init(testing.allocator, io, .{ .servers = &.{e2e.servers.cluster[2]} });
    defer publisher.deinit();
    try publisher.connect();
    const sub = try client.subscribe("e2e.failover", .{});
    defer sub.deinit();
    try client.flush(.{});
    try publishUntilReceived(&publisher, "e2e.failover", sub);

    // Node a goes down: the client moves to a node it learned of.
    try e2e.docker(&.{ "stop", e2e.servers.cluster_containers[0] });
    errdefer e2e.start(e2e.servers.cluster_containers[0]) catch {};
    _ = try awaitEvent(&client, .disconnected, 10);
    const moved = (try awaitEvent(&client, .reconnected, 10)).reconnected;
    try testing.expect(moved.port == 14227 or moved.port == 14228);
    try publishUntilReceived(&publisher, "e2e.failover", sub);

    // As it was, for the tests after this one.
    try e2e.start(e2e.servers.cluster_containers[0]);
    try e2e.awaitRoutes(0);
}

test "failover in a cluster: the client moves to a server the cluster announced" {
    try e2e.onZio(clusterFailover);
}

fn lameDuck(io: Io) !void {
    var client: nats.Client = try .init(testing.allocator, io, .{
        .servers = e2e.servers.cluster,
        .randomize_servers = false,
        .reconnect = quick_reconnect,
    });
    defer client.deinit();
    try client.connect();
    try testing.expectEqual(14226, client.connectedServer().?.port);
    var publisher: nats.Client = try .init(testing.allocator, io, .{ .servers = &.{e2e.servers.cluster[2]} });
    defer publisher.deinit();
    try publisher.connect();
    const sub = try client.subscribe("e2e.ldm", .{});
    defer sub.deinit();
    try client.flush(.{});
    try publishUntilReceived(&publisher, "e2e.ldm", sub);

    // Node a goes into lame duck mode, as before an upgrade: the client
    // leaves it at once, before the server closes its connection.
    try e2e.docker(&.{ "kill", "--signal", "SIGUSR2", e2e.servers.cluster_containers[0] });
    errdefer {
        e2e.awaitExited(e2e.servers.cluster_containers[0]) catch {};
        e2e.start(e2e.servers.cluster_containers[0]) catch {};
    }
    const start = Io.Clock.awake.now(io);
    try testing.expectEqual(14226, (try awaitEvent(&client, .lame_duck, 30)).lame_duck.port);
    const lost = (try awaitEvent(&client, .disconnected, 5)).disconnected;
    try testing.expectEqual(.lame_duck, lost.reason);
    const moved = (try awaitEvent(&client, .reconnected, 5)).reconnected;
    try testing.expect(moved.port != 14226);
    // The grace period of the server is 2 s: the client did not wait for it.
    try testing.expect(elapsedSince(io, start).toMilliseconds() < 2000);
    try publishUntilReceived(&publisher, "e2e.ldm", sub);

    // Node a stops once its clients are gone; then it starts again.
    try e2e.awaitExited(e2e.servers.cluster_containers[0]);
    try e2e.start(e2e.servers.cluster_containers[0]);
    try e2e.awaitRoutes(0);
}

test "lame duck mode: the client moves to another node at once, and its subscription with it" {
    try e2e.onZio(lameDuck);
}

/// Changes the password of `rotating` on the reload server: "second" with
/// `changed`, "first" again without.
fn setPassword(changed: bool) !void {
    const file = if (changed) "/conf/reload-new.conf" else "/conf/reload.conf";
    try e2e.docker(&.{ "exec", e2e.servers.reload_container, "cp", file, "/tmp/nats.conf" });
    try e2e.docker(&.{ "kill", "--signal", "SIGHUP", e2e.servers.reload_container });
}

fn passwordChange(io: Io) !void {
    var stopping: nats.Client = try .init(testing.allocator, io, .{
        .servers = &.{e2e.servers.reload},
        .auth = .{ .user_password = .{ .username = "rotating", .password = "first" } },
        .reconnect = quick_reconnect,
    });
    defer stopping.deinit();
    try stopping.connect();
    var trying: nats.Client = try .init(testing.allocator, io, .{
        .servers = &.{e2e.servers.reload},
        .auth = .{ .user_password = .{ .username = "rotating", .password = "first" } },
        .reconnect = .{ .min_delay = .fromMilliseconds(100), .max_delay = .fromMilliseconds(200), .abort_on_auth_error = false },
    });
    defer trying.deinit();
    try trying.connect();

    // The server reloads with a new password: both clients are refused
    // and dropped.
    try setPassword(true);
    errdefer setPassword(false) catch {};
    // The connection's refusal and the first attempt's: closed.
    _ = try awaitEvent(&stopping, .auth_error, 10);
    _ = try awaitEvent(&stopping, .auth_error, 10);
    try testing.expectEqual(.auth_failed, (try awaitEvent(&stopping, .closed, 10)).closed);
    try testing.expectEqual(.closed, stopping.state());

    // The other one goes on trying.
    for (0..3) |_| _ = try awaitEvent(&trying, .auth_error, 10);
    try testing.expectEqual(.reconnecting, trying.state());
    // The old password is back: it gets in.
    try setPassword(false);
    _ = try awaitEvent(&trying, .reconnected, 10);
    try trying.flush(.{});
}

test "a password changed on the server: two refusals stop the client, unless abort_on_auth_error is false" {
    try e2e.onZio(passwordChange);
}

fn pausedServer(io: Io) !void {
    var client: nats.Client = try .init(testing.allocator, io, .{
        .servers = &.{e2e.servers.stall},
        .ping_interval = .fromMilliseconds(100),
        .max_outstanding_pings = 2,
        .connect_timeout = .fromMilliseconds(500),
        .reconnect = quick_reconnect,
    });
    defer client.deinit();
    try client.connect();
    const sub = try client.subscribe("e2e.paused", .{});
    defer sub.deinit();
    try client.flush(.{});

    // The server stops answering, PINGs included: the heartbeat finds out.
    try e2e.docker(&.{ "pause", e2e.servers.stall_container });
    errdefer e2e.unpause(e2e.servers.stall_container) catch {};
    const start = Io.Clock.awake.now(io);
    try testing.expectEqual(.stale, (try awaitEvent(&client, .disconnected, 5)).disconnected.reason);
    try testing.expect(elapsedSince(io, start).toSeconds() < 2);
    // Publishes now wait for the next connection.
    try client.publish("e2e.paused", "while paused");
    // Attempts against the paused server time out until it comes back.
    _ = try awaitEvent(&client, .reconnecting, 5);
    try e2e.unpause(e2e.servers.stall_container);
    _ = try awaitEvent(&client, .reconnected, 15);
    try expectMessage(sub, "e2e.paused", "while paused");
    try client.publish("e2e.paused", "after");
    try expectMessage(sub, "e2e.paused", "after");
}

test "a server that hangs: the heartbeat drops the connection, and the client reconnects when it is back" {
    try e2e.onZio(pausedServer);
}

/// Answers each request on `sub` slowly, as a handler with work to do.
fn answerSlowly(client: *nats.Client, sub: *nats.Subscription, answered: *std.atomic.Value(u32)) anyerror!void {
    while (true) {
        var msg = (try sub.next(.{})) orelse return;
        defer msg.deinit();
        try client.io.sleep(.fromMilliseconds(100), .awake);
        try client.respond(&msg, msg.payload);
        _ = answered.fetchAdd(1, .monotonic);
    }
}

fn requestNumber(client: *nats.Client, i: usize, ok: *std.atomic.Value(u32)) void {
    var buffer: [8]u8 = undefined;
    const payload = std.fmt.bufPrint(&buffer, "{d}", .{i}) catch return;
    var reply = client.request("e2e.drain.work", payload, .{ .timeout = duration(10_000) }) catch return;
    defer reply.deinit();
    if (std.mem.eql(u8, reply.payload, payload)) _ = ok.fetchAdd(1, .monotonic);
}

fn drainWhileAnswering(io: Io) !void {
    var worker: nats.Client = try .init(testing.allocator, io, .{ .servers = &.{e2e.servers.plain} });
    defer worker.deinit();
    try worker.connect();
    const work = try worker.subscribe("e2e.drain.work", .{});
    defer work.deinit();
    try worker.flush(.{});
    var answered: std.atomic.Value(u32) = .init(0);
    var handler = try io.concurrent(answerSlowly, .{ &worker, work, &answered });
    defer handler.cancel(io) catch {};

    var asker: nats.Client = try .init(testing.allocator, io, .{ .servers = &.{e2e.servers.plain} });
    defer asker.deinit();
    try asker.connect();
    var ok: std.atomic.Value(u32) = .init(0);
    var group: Io.Group = .init;
    defer group.cancel(io);
    const count = 5;
    for (0..count) |i| try group.concurrent(io, requestNumber, .{ &asker, i, &ok });
    // Every request reached the handler, which has answered at most one.
    const start = Io.Clock.awake.now(io);
    while (work.stats().received < count) {
        if (elapsedSince(io, start).toSeconds() >= 5) return error.TestRequestsNeverCame;
        try io.sleep(.fromMilliseconds(5), .awake);
    }
    try testing.expect(answered.load(.monotonic) < count);

    // The worker drains while its handler still answers.
    try worker.drain(.{ .timeout = duration(10_000) });
    try testing.expectEqual(.closed, worker.state());
    try handler.await(io);
    try group.await(io);
    try testing.expectEqual(count, answered.load(.monotonic));
    try testing.expectEqual(count, ok.load(.monotonic));
    // No one answers any more.
    try testing.expectError(error.NoResponders, asker.request("e2e.drain.work", "late", .{}));
}

test "drain while a handler still answers requests: every request gets its answer, then the client closes" {
    try e2e.onZio(drainWhileAnswering);
}

fn retryInitialConnect(io: Io) !void {
    // The server is down when the client starts.
    try e2e.docker(&.{ "stop", e2e.servers.restart_container });
    errdefer e2e.start(e2e.servers.restart_container) catch {};
    var client: nats.Client = try .init(testing.allocator, io, .{
        .servers = &.{e2e.servers.restart},
        .retry_initial_connect = true,
        .connect_timeout = .fromSeconds(1),
        .reconnect = quick_reconnect,
    });
    defer client.deinit();
    const start = Io.Clock.awake.now(io);
    try client.connect();
    try testing.expect(elapsedSince(io, start).toSeconds() < 1);
    try testing.expectEqual(.reconnecting, client.state());
    // A subscription and a publish made before the first connection.
    const early = try client.subscribe("e2e.retry", .{});
    defer early.deinit();
    try client.publish("e2e.retry", "early");
    _ = try awaitEvent(&client, .reconnecting, 5);

    try e2e.start(e2e.servers.restart_container);
    _ = try awaitEvent(&client, .connected, 10);
    try expectMessage(early, "e2e.retry", "early");
    try client.flush(.{});
}

test "retry_initial_connect: the client starts while its server is down, and connects once it is up" {
    try e2e.onZio(retryInitialConnect);
}
