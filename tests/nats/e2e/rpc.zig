//! Requests and replies on live servers: request/reply with headers, no
//! responders, timeouts, cancellation, late replies, respond and
//! respondMessage, requestMany with three responders, a lost connection,
//! and 10,000 requests at once through one inbox subscription.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const nats = @import("nats");
const e2e = @import("root.zig");

fn within(milliseconds: i64) nats.RequestOptions {
    return .{ .timeout = .{ .duration = .{ .raw = .fromMilliseconds(milliseconds), .clock = .awake } } };
}

fn manyWithin(milliseconds: i64, max_responses: u32) nats.RequestManyOptions {
    return .{ .timeout = .{ .duration = .{ .raw = .fromMilliseconds(milliseconds), .clock = .awake } }, .max_responses = max_responses };
}

const within_five_seconds: nats.ReceiveOptions = .{ .timeout = .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } } };

fn elapsedSince(io: Io, start: Io.Timestamp) Io.Duration {
    return start.durationTo(Io.Clock.awake.now(io));
}

/// How a responder answers.
const Answer = union(enum) {
    /// The payload back, with `X-Echo: yes` and the request's `X-Ask` as
    /// `X-Ask-Was`, through respondMessage.
    echo,
    /// The payload back, through respond.
    same,
    /// The payload back, through respond, once this many requests came:
    /// until then they all wait.
    same_after: u32,
    /// This text, through respond.
    text: []const u8,
    /// The payload back after this many milliseconds.
    delayed: i64,
    /// "and you?", with a reply subject for the requester to answer.
    converse: []const u8,
};

/// A client of its own that answers the requests to one subject until
/// `stop()`. Initialize it in place with `start`: the client must not move.
const Responder = struct {
    client: nats.Client,
    sub: *nats.Subscription,
    task: Io.Future(anyerror!void),

    fn start(r: *Responder, io: Io, subject: []const u8, answer: Answer) !void {
        r.client = try .init(testing.allocator, io, .{ .servers = &.{e2e.servers.plain} });
        errdefer r.client.deinit();
        try r.client.connect();
        r.sub = try r.client.subscribe(subject, .{ .pending = .{ .messages = 20_000 } });
        errdefer r.sub.deinit();
        // The server has the SUB before anyone asks.
        try r.client.flush(.{});
        r.task = try io.concurrent(serve, .{ &r.client, r.sub, answer });
    }

    /// Stops answering; fails if answering failed.
    fn stop(r: *Responder, io: Io) !void {
        try r.sub.unsubscribe();
        try r.task.await(io);
    }

    fn deinit(r: *Responder, io: Io) void {
        r.task.cancel(io) catch {};
        r.sub.deinit();
        r.client.deinit();
    }

    fn serve(client: *nats.Client, sub: *nats.Subscription, answer: Answer) anyerror!void {
        const io = client.io;
        if (answer == .same_after) {
            const began = Io.Clock.awake.now(io);
            while (sub.stats().received < answer.same_after) {
                if (elapsedSince(io, began).toSeconds() >= 60) return error.TestRequestsNeverCame;
                try io.sleep(.fromMilliseconds(5), .awake);
            }
        }
        while (true) {
            var msg = (try sub.next(.{})) orelse return;
            defer msg.deinit();
            switch (answer) {
                .echo => try client.respondMessage(&msg, .{
                    .headers = &.{
                        .{ .name = "X-Echo", .value = "yes" },
                        .{ .name = "X-Ask-Was", .value = msg.headers.get("X-Ask") orelse "none" },
                    },
                    .payload = msg.payload,
                }),
                .same, .same_after => try client.respond(&msg, msg.payload),
                .text => |text| try client.respond(&msg, text),
                .delayed => |ms| {
                    try io.sleep(.fromMilliseconds(ms), .awake);
                    try client.respond(&msg, msg.payload);
                },
                .converse => |next_subject| try client.respondMessage(&msg, .{ .reply_to = next_subject, .payload = "and you?" }),
            }
        }
    }
};

/// Sends request number `i` to `subject` and counts it in `ok` when the
/// reply carries the same number.
fn requestNumber(client: *nats.Client, subject: []const u8, i: usize, ok: *std.atomic.Value(u32), failed: *std.atomic.Value(u32)) void {
    var buffer: [20]u8 = undefined;
    const payload = buffer[0..std.fmt.printInt(&buffer, i, 10, .lower, .{})];
    var reply = client.request(subject, payload, within(60_000)) catch {
        _ = failed.fetchAdd(1, .monotonic);
        return;
    };
    defer reply.deinit();
    if (std.mem.eql(u8, reply.payload, payload)) {
        _ = ok.fetchAdd(1, .monotonic);
    } else {
        _ = failed.fetchAdd(1, .monotonic);
    }
}

fn requestReply(io: Io) !void {
    var responder: Responder = undefined;
    try responder.start(io, "e2e.rpc.echo", .echo);
    defer responder.deinit(io);
    var client: nats.Client = try .init(testing.allocator, io, .{ .servers = &.{e2e.servers.plain} });
    defer client.deinit();
    try client.connect();

    {
        var reply = try client.request("e2e.rpc.echo", "ping", .{});
        defer reply.deinit();
        try testing.expectEqualStrings("ping", reply.payload);
        try testing.expectEqualStrings("yes", reply.headers.get("X-Echo").?);
        try testing.expectEqualStrings("none", reply.headers.get("X-Ask-Was").?);
    }
    {
        var reply = try client.requestMessage(.{
            .subject = "e2e.rpc.echo",
            .headers = &.{.{ .name = "X-Ask", .value = "42" }},
            .payload = "with headers",
        }, .{});
        defer reply.deinit();
        try testing.expectEqualStrings("with headers", reply.payload);
        try testing.expectEqualStrings("42", reply.headers.get("X-Ask-Was").?);
    }
    // In a row, then at once: every one through the same inbox.
    var ok: std.atomic.Value(u32) = .init(0);
    var failed: std.atomic.Value(u32) = .init(0);
    for (0..20) |i| requestNumber(&client, "e2e.rpc.echo", i, &ok, &failed);
    var group: Io.Group = .init;
    defer group.cancel(io);
    for (0..50) |i| try group.concurrent(io, requestNumber, .{ &client, "e2e.rpc.echo", i, &ok, &failed });
    try group.await(io);
    try testing.expectEqual(70, ok.load(.monotonic));
    try testing.expectEqual(0, client.inbox.pendingCount(io));
    try testing.expectEqual(0, client.inbox.lateResponses(io));
    try responder.stop(io);
}

test "request and requestMessage get their replies, headers included" {
    try e2e.onZio(requestReply);
}

fn noResponders(io: Io) !void {
    var client: nats.Client = try .init(testing.allocator, io, .{ .servers = &.{e2e.servers.plain} });
    defer client.deinit();
    try client.connect();
    const start = Io.Clock.awake.now(io);
    // The server answers at once, long before the timeout.
    try testing.expectError(error.NoResponders, client.request("e2e.rpc.nobody", "?", within(5000)));
    const responses = try client.requestMany("e2e.rpc.nobody", "?", manyWithin(5000, 32));
    try testing.expectError(error.NoResponders, responses.next(.{}));
    responses.deinit();
    try testing.expect(elapsedSince(io, start).toSeconds() < 4);
    try testing.expectEqual(0, client.inbox.pendingCount(io));
}

test "no responders: NoResponders at once, for request and requestMany" {
    try e2e.onZio(noResponders);
}

fn timeoutWithoutReply(io: Io) !void {
    var client: nats.Client = try .init(testing.allocator, io, .{ .servers = &.{e2e.servers.plain} });
    defer client.deinit();
    try client.connect();
    // Someone subscribes, but never answers.
    const silent = try client.subscribe("e2e.rpc.silent", .{});
    defer silent.deinit();
    try client.flush(.{});
    const start = Io.Clock.awake.now(io);
    try testing.expectError(error.Timeout, client.request("e2e.rpc.silent", "?", within(200)));
    const took = elapsedSince(io, start).toMilliseconds();
    try testing.expect(took >= 200 and took < 2000);
    try testing.expectEqual(0, client.inbox.pendingCount(io));
    try client.flush(.{});
}

test "a request no one answers ends with Timeout at its deadline" {
    try e2e.onZio(timeoutWithoutReply);
}

fn requestSilent(client: *nats.Client) nats.Client.RequestError!nats.Message {
    return client.request("e2e.rpc.silent", "?", within(30_000));
}

fn releaseReply(result: nats.Client.RequestError!nats.Message) void {
    if (result) |reply| {
        var m = reply;
        m.deinit();
    } else |_| {}
}

/// Waits until `count` requests wait for their replies, for 5 s at most.
fn awaitAwaiting(io: Io, client: *nats.Client, count: u32) !void {
    const start = Io.Clock.awake.now(io);
    while (client.inbox.awaitingCount(io) < count) {
        if (elapsedSince(io, start).toSeconds() >= 5) return error.TestNeverWaited;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}

fn cancelRequest(io: Io) !void {
    var client: nats.Client = try .init(testing.allocator, io, .{ .servers = &.{e2e.servers.plain} });
    defer client.deinit();
    try client.connect();
    const silent = try client.subscribe("e2e.rpc.silent", .{});
    defer silent.deinit();
    try client.flush(.{});
    var request = try io.concurrent(requestSilent, .{&client});
    defer releaseReply(request.cancel(io));
    try awaitAwaiting(io, &client, 1);
    const start = Io.Clock.awake.now(io);
    if (request.cancel(io)) |_| return error.TestUnexpectedReply else |err| try testing.expectEqual(error.Canceled, err);
    try testing.expect(elapsedSince(io, start).toSeconds() < 1);
    try testing.expectEqual(0, client.inbox.pendingCount(io));
    // The client goes on.
    try client.flush(.{});
    try testing.expect(client.isConnected());
}

test "a canceled request returns Canceled and leaves nothing behind" {
    try e2e.onZio(cancelRequest);
}

fn lateReply(io: Io) !void {
    var responder: Responder = undefined;
    try responder.start(io, "e2e.rpc.slow", .{ .delayed = 300 });
    defer responder.deinit(io);
    var client: nats.Client = try .init(testing.allocator, io, .{ .servers = &.{e2e.servers.plain} });
    defer client.deinit();
    try client.connect();
    try testing.expectError(error.Timeout, client.request("e2e.rpc.slow", "late", within(100)));
    // The reply comes after the request gave up: it counts as late.
    const start = Io.Clock.awake.now(io);
    while (client.inbox.lateResponses(io) < 1) {
        if (elapsedSince(io, start).toSeconds() >= 5) return error.TestNoLateReply;
        try io.sleep(.fromMilliseconds(10), .awake);
    }
    try testing.expectEqual(1, client.inbox.lateResponses(io));
    try testing.expectEqual(0, client.inbox.pendingCount(io));
    try responder.stop(io);
}

test "a reply after the timeout counts as late" {
    try e2e.onZio(lateReply);
}

fn respondAndRespondMessage(io: Io) !void {
    var responder: Responder = undefined;
    try responder.start(io, "e2e.rpc.conv", .{ .converse = "e2e.rpc.conv.next" });
    defer responder.deinit(io);
    var client: nats.Client = try .init(testing.allocator, io, .{ .servers = &.{e2e.servers.plain} });
    defer client.deinit();
    try client.connect();
    const follow_up = try client.subscribe("e2e.rpc.conv.next", .{});
    defer follow_up.deinit();
    const told = try client.subscribe("e2e.rpc.told", .{});
    defer told.deinit();
    try client.flush(.{});

    // respondMessage gave the response a reply subject: the requester
    // answers it with respond.
    var reply = try client.request("e2e.rpc.conv", "hello", .{});
    defer reply.deinit();
    try testing.expectEqualStrings("and you?", reply.payload);
    try testing.expectEqualStrings("e2e.rpc.conv.next", reply.reply_to.?);
    try client.respond(&reply, "fine");
    var answer = (try follow_up.next(within_five_seconds)) orelse return error.TestNoMessage;
    defer answer.deinit();
    try testing.expectEqualStrings("fine", answer.payload);

    // A message published without a reply subject has no one to answer.
    try client.publish("e2e.rpc.told", "no reply wanted");
    var msg = (try told.next(within_five_seconds)) orelse return error.TestNoMessage;
    defer msg.deinit();
    try testing.expect(msg.reply_to == null);
    try testing.expectError(error.NoReplySubject, client.respond(&msg, "x"));
    try testing.expectError(error.NoReplySubject, client.respondMessage(&msg, .{ .payload = "x" }));
    try client.flush(.{});
    try testing.expect(client.isConnected());
    try responder.stop(io);
}

test "respond and respondMessage answer requests; a message without a reply subject is NoReplySubject" {
    try e2e.onZio(respondAndRespondMessage);
}

/// Takes every response until the stream ends; marks each responder's
/// name in `seen` and returns how many came.
fn collectNames(responses: *nats.Responses, names: []const []const u8, seen: []bool) !usize {
    var count: usize = 0;
    while (true) {
        var msg = (try responses.next(.{})) orelse return count;
        defer msg.deinit();
        for (names, seen) |name, *flag| {
            if (std.mem.eql(u8, name, msg.payload)) flag.* = true;
        }
        count += 1;
    }
}

fn requestManyThree(io: Io) !void {
    const names = [_][]const u8{ "a", "b", "c" };
    var responders: [names.len]Responder = undefined;
    var started: usize = 0;
    defer for (responders[0..started]) |*r| r.deinit(io);
    for (&responders, names) |*r, name| {
        try r.start(io, "e2e.rpc.many", .{ .text = name });
        started += 1;
    }
    var client: nats.Client = try .init(testing.allocator, io, .{ .servers = &.{e2e.servers.plain} });
    defer client.deinit();
    try client.connect();

    // By its deadline: all three answer, and the stream ends only then.
    {
        const start = Io.Clock.awake.now(io);
        const responses = try client.requestMany("e2e.rpc.many", "who?", manyWithin(500, 32));
        defer responses.deinit();
        var seen: [names.len]bool = @splat(false);
        try testing.expectEqual(3, try collectNames(responses, &names, &seen));
        try testing.expect(seen[0] and seen[1] and seen[2]);
        try testing.expect(elapsedSince(io, start).toMilliseconds() >= 500);
    }
    // By max_responses: two, long before the deadline; the third is late.
    {
        const start = Io.Clock.awake.now(io);
        const responses = try client.requestMany("e2e.rpc.many", "who?", manyWithin(10_000, 2));
        defer responses.deinit();
        var seen: [names.len]bool = @splat(false);
        try testing.expectEqual(2, try collectNames(responses, &names, &seen));
        try testing.expect(elapsedSince(io, start).toSeconds() < 5);
    }
    const start = Io.Clock.awake.now(io);
    while (client.inbox.lateResponses(io) < 1) {
        if (elapsedSince(io, start).toSeconds() >= 5) return error.TestNoLateReply;
        try io.sleep(.fromMilliseconds(10), .awake);
    }
    try testing.expectEqual(1, client.inbox.lateResponses(io));
    try testing.expectEqual(0, client.inbox.pendingCount(io));
    for (&responders) |*r| try r.stop(io);
}

test "requestMany with three responders ends by its deadline and by max_responses" {
    try e2e.onZio(requestManyThree);
}

fn requestLost(client: *nats.Client) nats.Client.RequestError!nats.Message {
    return client.request("e2e.rpc.lost", "?", within(30_000));
}

fn connectionLost(io: Io) !void {
    var client: nats.Client = try .init(testing.allocator, io, .{
        .servers = &.{e2e.servers.stall},
        .ping_interval = .fromMilliseconds(100),
        .max_outstanding_pings = 2,
    });
    defer client.deinit();
    try client.connect();
    // Interest, so that the server does not answer "no responders"; no one
    // answers.
    const lost = try client.subscribe("e2e.rpc.lost", .{});
    defer lost.deinit();
    try client.flush(.{});
    const responses = try client.requestMany("e2e.rpc.lost", "?", manyWithin(30_000, 32));
    defer responses.deinit();
    var request = try io.concurrent(requestLost, .{&client});
    defer releaseReply(request.cancel(io));
    try awaitAwaiting(io, &client, 1);

    // The server stops answering, PINGs included: the heartbeat drops the
    // connection, and every request waiting fails at once.
    try e2e.docker(&.{ "pause", e2e.servers.stall_container });
    errdefer e2e.unpause(e2e.servers.stall_container) catch {};
    const start = Io.Clock.awake.now(io);
    if (request.await(io)) |_| return error.TestUnexpectedReply else |err| try testing.expectEqual(error.Disconnected, err);
    try testing.expectError(error.Disconnected, responses.next(.{}));
    try testing.expect(elapsedSince(io, start).toSeconds() < 5);
    // As it was, for the tests after this one.
    try e2e.unpause(e2e.servers.stall_container);
}

test "a lost connection fails the waiting requests with Disconnected at once" {
    try e2e.onZio(connectionLost);
}

/// The server's view of the connection named `name`: one subscription, the
/// inbox `_INBOX.<22 characters>.*`.
fn expectOneInboxSubscription(name: []const u8) !void {
    const json = try e2e.dockerOutput(&.{ "exec", e2e.servers.plain_container, "wget", "-q", "-O", "-", "http://127.0.0.1:8222/connz?subs=1" });
    defer testing.allocator.free(json);
    const Connection = struct {
        name: ?[]const u8 = null,
        subscriptions: u32 = 0,
        subscriptions_list: ?[]const []const u8 = null,
    };
    const Connz = struct { connections: []const Connection = &.{} };
    const parsed = try std.json.parseFromSlice(Connz, testing.allocator, json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    for (parsed.value.connections) |connection| {
        const its_name = connection.name orelse continue;
        if (!std.mem.eql(u8, its_name, name)) continue;
        try testing.expectEqual(1, connection.subscriptions);
        const list = connection.subscriptions_list orelse return error.TestNoSubscriptionList;
        try testing.expectEqual(1, list.len);
        try testing.expect(std.mem.startsWith(u8, list[0], "_INBOX.") and std.mem.endsWith(u8, list[0], ".*"));
        try testing.expectEqual("_INBOX.".len + 22 + ".*".len, list[0].len);
        return;
    }
    return error.TestConnectionNotFound;
}

fn tenThousand(io: Io) !void {
    const count = 10_000;
    var responder: Responder = undefined;
    try responder.start(io, "e2e.rpc.10k", .{ .same_after = count });
    defer responder.deinit(io);
    var client: nats.Client = try .init(testing.allocator, io, .{ .servers = &.{e2e.servers.plain}, .name = "e2e-rpc-10k" });
    defer client.deinit();
    try client.connect();
    var ok: std.atomic.Value(u32) = .init(0);
    var failed: std.atomic.Value(u32) = .init(0);
    var group: Io.Group = .init;
    defer group.cancel(io);
    for (0..count) |i| try group.concurrent(io, requestNumber, .{ &client, "e2e.rpc.10k", i, &ok, &failed });
    // The responder answers once all of them came: they all wait at once.
    const start = Io.Clock.awake.now(io);
    while (client.inbox.pendingCount(io) < count) {
        if (elapsedSince(io, start).toSeconds() >= 60) return error.TestRequestsNeverPending;
        try io.sleep(.fromMilliseconds(5), .awake);
    }
    try group.await(io);
    if (ok.load(.monotonic) != 10_000) {
        std.debug.print("10k requests: {d} ok, {d} failed\n", .{ ok.load(.monotonic), failed.load(.monotonic) });
        return error.TestRequestsFailed;
    }
    try expectOneInboxSubscription("e2e-rpc-10k");
    try testing.expectEqual(0, client.inbox.pendingCount(io));
    try testing.expectEqual(0, client.inbox.lateResponses(io));
    try responder.stop(io);
}

test "10,000 requests at once go through one inbox subscription" {
    try e2e.onZio(tenThousand);
}
