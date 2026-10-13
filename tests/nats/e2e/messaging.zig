//! Publishing and subscribing on live servers: PUB and SUB, wildcards,
//! queue groups, headers, auto-unsubscribe, slow consumers, permissions,
//! limits, and closing while tasks wait.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const nats = @import("nats");
const e2e = @import("root.zig");

const within_five_seconds: nats.ReceiveOptions = .{ .timeout = .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } } };
const briefly: nats.ReceiveOptions = .{ .timeout = .{ .duration = .{ .raw = .fromMilliseconds(50), .clock = .awake } } };

fn elapsedSince(io: Io, start: Io.Timestamp) Io.Duration {
    return start.durationTo(Io.Clock.awake.now(io));
}

/// Takes the next message of `sub` and checks its subject and payload.
fn expectMessage(sub: *nats.Subscription, subject: []const u8, payload: []const u8) !void {
    var msg = (try sub.next(within_five_seconds)) orelse return error.TestNoMessage;
    defer msg.deinit();
    try testing.expectEqualStrings(subject, msg.subject);
    try testing.expectEqualStrings(payload, msg.payload);
}

/// Nothing more comes for `sub`.
fn expectNothing(sub: *nats.Subscription) !void {
    try testing.expectError(error.Timeout, sub.next(briefly));
}

fn pubSubAndWildcards(io: Io) !void {
    var client: nats.Client = try .init(testing.allocator, io, .{ .servers = &.{e2e.servers.plain} });
    defer client.deinit();
    try client.connect();
    const exact = try client.subscribe("e2e.ps.a", .{});
    defer exact.deinit();
    const star = try client.subscribe("e2e.ps.*", .{});
    defer star.deinit();
    const tail = try client.subscribe("e2e.ps.>", .{});
    defer tail.deinit();
    // The server has the SUBs before the first PUB.
    try client.flush(.{});

    try client.publish("e2e.ps.a", "1");
    try client.publish("e2e.ps.a.b", "2");
    try client.publish("e2e.ps", "3");
    try client.flush(.{});
    try expectMessage(exact, "e2e.ps.a", "1");
    try expectMessage(star, "e2e.ps.a", "1");
    try expectMessage(tail, "e2e.ps.a", "1");
    try expectMessage(tail, "e2e.ps.a.b", "2");
    try expectNothing(exact);
    try expectNothing(star);
    try expectNothing(tail);

    // Many messages come in the order they went.
    var buffer: [8]u8 = undefined;
    for (0..200) |i| try client.publish("e2e.ps.a", try std.fmt.bufPrint(&buffer, "{d}", .{i}));
    try client.flush(.{});
    for (0..200) |i| try expectMessage(exact, "e2e.ps.a", try std.fmt.bufPrint(&buffer, "{d}", .{i}));
}

test "PUB and SUB, with * and > wildcards" {
    try e2e.onZio(pubSubAndWildcards);
}

/// Takes every message waiting in `sub` and marks its number in `seen`;
/// returns how many there were. A number seen twice fails.
fn collect(sub: *nats.Subscription, seen: []bool) !usize {
    var count: usize = 0;
    while (true) {
        var msg = (sub.next(briefly) catch |err| switch (err) {
            error.Timeout => return count,
            else => |e| return e,
        }) orelse return count;
        defer msg.deinit();
        const n = try std.fmt.parseInt(usize, msg.payload, 10);
        if (seen[n]) return error.TestDuplicate;
        seen[n] = true;
        count += 1;
    }
}

fn queueGroup(io: Io) !void {
    var first: nats.Client = try .init(testing.allocator, io, .{ .servers = &.{e2e.servers.plain} });
    defer first.deinit();
    try first.connect();
    var second: nats.Client = try .init(testing.allocator, io, .{ .servers = &.{e2e.servers.plain} });
    defer second.deinit();
    try second.connect();
    var publisher: nats.Client = try .init(testing.allocator, io, .{ .servers = &.{e2e.servers.plain} });
    defer publisher.deinit();
    try publisher.connect();
    const a = try first.subscribe("e2e.queue", .{ .queue = "workers" });
    defer a.deinit();
    const b = try second.subscribe("e2e.queue", .{ .queue = "workers" });
    defer b.deinit();
    try first.flush(.{});
    try second.flush(.{});

    var buffer: [8]u8 = undefined;
    for (0..100) |i| try publisher.publish("e2e.queue", try std.fmt.bufPrint(&buffer, "{d}", .{i}));
    try publisher.flush(.{});
    // A PONG comes after every message the server queued before it.
    try first.flush(.{});
    try second.flush(.{});

    var seen: [100]bool = @splat(false);
    const to_a = try collect(a, &seen);
    const to_b = try collect(b, &seen);
    // Each message went to one member of the group; both got some.
    try testing.expectEqual(100, to_a + to_b);
    try testing.expect(to_a > 0 and to_b > 0);
}

test "a queue group: two subscribers share the stream" {
    try e2e.onZio(queueGroup);
}

fn headersAndBinary(io: Io) !void {
    var client: nats.Client = try .init(testing.allocator, io, .{ .servers = &.{e2e.servers.plain} });
    defer client.deinit();
    try client.connect();
    const sub = try client.subscribe("e2e.hdr", .{});
    defer sub.deinit();
    try client.flush(.{});

    var payload: [256]u8 = undefined;
    for (&payload, 0..) |*byte, i| byte.* = @intCast(i);
    try client.publishMessage(.{
        .subject = "e2e.hdr",
        .reply_to = "e2e.hdr.reply",
        .headers = &.{
            .{ .name = "X-Multi", .value = "one" },
            .{ .name = "X-Multi", .value = "two" },
            .{ .name = "X-Single", .value = "v" },
        },
        .payload = &payload,
    });
    try client.flush(.{});

    var msg = (try sub.next(within_five_seconds)) orelse return error.TestNoMessage;
    defer msg.deinit();
    try testing.expectEqualStrings("e2e.hdr", msg.subject);
    try testing.expectEqualStrings("e2e.hdr.reply", msg.reply_to.?);
    try testing.expectEqualSlices(u8, &payload, msg.payload);
    var values = msg.headers.getAll("X-Multi");
    try testing.expectEqualStrings("one", values.next().?);
    try testing.expectEqualStrings("two", values.next().?);
    try testing.expect(values.next() == null);
    try testing.expectEqualStrings("v", msg.headers.get("X-Single").?);
    try testing.expect(msg.headers.get("x-single") == null);
    try testing.expect(msg.status == null);
}

test "HPUB and HMSG: multi-value headers and a binary payload" {
    try e2e.onZio(headersAndBinary);
}

fn autoUnsubscribe(io: Io) !void {
    var client: nats.Client = try .init(testing.allocator, io, .{ .servers = &.{e2e.servers.plain} });
    defer client.deinit();
    try client.connect();
    const once = try client.subscribe("e2e.once", .{ .max_messages = 3 });
    defer once.deinit();
    try client.flush(.{});
    for ([_][]const u8{ "1", "2", "3", "4", "5" }) |payload| try client.publish("e2e.once", payload);
    try client.flush(.{});
    try expectMessage(once, "e2e.once", "1");
    try expectMessage(once, "e2e.once", "2");
    try expectMessage(once, "e2e.once", "3");
    try testing.expect(try once.next(within_five_seconds) == null);
    try testing.expectEqual(3, once.stats().received);
}

test "auto-unsubscribe after max_messages" {
    try e2e.onZio(autoUnsubscribe);
}

/// Five messages to a subscription that holds two, read only afterwards.
fn slowConsumer(io: Io, overflow: nats.OverflowPolicy, subject: []const u8) !void {
    var client: nats.Client = try .init(testing.allocator, io, .{ .servers = &.{e2e.servers.plain} });
    defer client.deinit();
    try client.connect();
    const slow = try client.subscribe(subject, .{ .pending = .{ .messages = 2 }, .overflow = overflow });
    defer slow.deinit();
    try client.flush(.{});
    for ([_][]const u8{ "1", "2", "3", "4", "5" }) |payload| try client.publish(subject, payload);
    // Every message is in before the PONG.
    try client.flush(.{});
    switch (overflow) {
        .drop_newest => {
            try expectMessage(slow, subject, "1");
            try expectMessage(slow, subject, "2");
            try expectNothing(slow);
            try testing.expectEqual(nats.SubscriptionStats{ .received = 5, .delivered = 2, .dropped = 3 }, slow.stats());
        },
        .drop_oldest => {
            try expectMessage(slow, subject, "4");
            try expectMessage(slow, subject, "5");
            try expectNothing(slow);
            try testing.expectEqual(nats.SubscriptionStats{ .received = 5, .delivered = 2, .dropped = 3 }, slow.stats());
        },
        .close_subscription => {
            try expectMessage(slow, subject, "1");
            try expectMessage(slow, subject, "2");
            try testing.expectError(error.SlowConsumer, slow.next(within_five_seconds));
            try testing.expectEqual(nats.SubscriptionStats{ .received = 3, .delivered = 2, .dropped = 1 }, slow.stats());
        },
    }
    // The connection is fine.
    try client.flush(.{});
}

fn slowConsumers(io: Io) !void {
    try slowConsumer(io, .drop_newest, "e2e.slow.newest");
    try slowConsumer(io, .drop_oldest, "e2e.slow.oldest");
    try slowConsumer(io, .close_subscription, "e2e.slow.close");
}

test "a slow consumer under each overflow policy" {
    try e2e.onZio(slowConsumers);
}

fn permissions(io: Io) !void {
    // "limited" may not publish to secret.> nor subscribe to forbidden or
    // forbidden.>.
    var client: nats.Client = try .init(testing.allocator, io, .{
        .servers = &.{e2e.servers.auth},
        .auth = .{ .user_password = .{ .username = "limited", .password = "limited" } },
    });
    defer client.deinit();
    try client.connect();
    const allowed = try client.subscribe("e2e.allowed", .{});
    defer allowed.deinit();

    // The server drops the message and says so; the connection stays.
    try client.publish("secret.x", "x");
    try client.flush(.{});
    try testing.expect(client.isConnected());

    const denied = try client.subscribe("forbidden", .{});
    defer denied.deinit();
    try testing.expectError(error.PermissionDenied, denied.next(within_five_seconds));
    // The server quotes this subject with escapes; the client reads them.
    const odd = try client.subscribe("forbidden.q\"uo\\te.ü", .{});
    defer odd.deinit();
    try testing.expectError(error.PermissionDenied, odd.next(within_five_seconds));

    try client.publish("e2e.allowed", "still here");
    try client.flush(.{});
    try expectMessage(allowed, "e2e.allowed", "still here");
    try testing.expect(client.isConnected());
}

test "a restricted user: a refused publish keeps the connection, a refused subscription gives PermissionDenied" {
    try e2e.onZio(permissions);
}

fn inboundLimit(io: Io) !void {
    var client: nats.Client = try .init(testing.allocator, io, .{
        .servers = &.{e2e.servers.plain},
        .limits = .{ .max_inbound_frame_bytes = 1024, .max_header_bytes = 512 },
    });
    defer client.deinit();
    try client.connect();
    const sub = try client.subscribe("e2e.big", .{});
    defer sub.deinit();
    try client.flush(.{});
    const at_limit: [1024]u8 = @splat('a');
    const over: [1025]u8 = @splat('b');
    try client.publish("e2e.big", &at_limit);
    try client.publish("e2e.big", &over);
    try client.publish("e2e.big", "after");
    try client.flush(.{});
    try expectMessage(sub, "e2e.big", &at_limit);
    try expectMessage(sub, "e2e.big", "after");
    try testing.expectEqual(nats.SubscriptionStats{ .received = 3, .delivered = 2, .dropped = 1 }, sub.stats());
}

test "a message over max_inbound_frame_bytes is dropped, and the next one arrives whole" {
    try e2e.onZio(inboundLimit);
}

fn nextLong(sub: *nats.Subscription) nats.Subscription.NextError!?nats.Message {
    return sub.next(.{ .timeout = .{ .duration = .{ .raw = .fromSeconds(30), .clock = .awake } } });
}

/// Waits until a task waits in `sub.next()`, for 5 s at most.
fn awaitReceiving(io: Io, sub: *nats.Subscription) !void {
    const start = Io.Clock.awake.now(io);
    while (!sub.messages.isReceiving(io)) {
        if (elapsedSince(io, start).toSeconds() >= 5) return error.TestReceiverNeverWaited;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}

fn closeDuringNext(io: Io) !void {
    var client: nats.Client = try .init(testing.allocator, io, .{ .servers = &.{e2e.servers.plain} });
    defer client.deinit();
    try client.connect();
    const idle = try client.subscribe("e2e.idle", .{});
    defer idle.deinit();
    var receiver = try io.concurrent(nextLong, .{idle});
    defer _ = receiver.cancel(io) catch null;
    try awaitReceiving(io, idle);
    const start = Io.Clock.awake.now(io);
    client.close();
    try testing.expectError(error.ConnectionClosed, receiver.await(io));
    try testing.expect(elapsedSince(io, start).toSeconds() < 1);
}

test "close() while a task waits in next(): ConnectionClosed at once" {
    try e2e.onZio(closeDuringNext);
}

/// Publishes large messages until it fails; counts the ones that went in.
fn publishUntilClosed(client: *nats.Client, payload: []const u8, published: *std.atomic.Value(u32)) nats.Client.PublishError!void {
    while (true) {
        try client.publish("e2e.stall", payload);
        _ = published.fetchAdd(1, .monotonic);
    }
}

fn closeDuringStalledPublish(io: Io) !void {
    var client: nats.Client = try .init(testing.allocator, io, .{ .servers = &.{e2e.servers.stall}, .limits = .{ .outbound_bytes = 1 } });
    defer client.deinit();
    try client.connect();
    // The server stops reading: the socket fills, then the outbound queue.
    try e2e.docker(&.{ "pause", e2e.servers.stall_container });
    errdefer e2e.unpause(e2e.servers.stall_container) catch {};

    const payload = try testing.allocator.alloc(u8, 512 * 1024);
    defer testing.allocator.free(payload);
    @memset(payload, 's');
    var published: std.atomic.Value(u32) = .init(0);
    var publisher = try io.concurrent(publishUntilClosed, .{ &client, payload, &published });
    defer publisher.cancel(io) catch {};

    // Stuck: a publish waits for room, and none went in for a while.
    const start = Io.Clock.awake.now(io);
    var last = published.load(.monotonic);
    var still_since = Io.Clock.awake.now(io);
    while (true) {
        try io.sleep(.fromMilliseconds(20), .awake);
        const now = published.load(.monotonic);
        if (now != last or client.outbound.roomWaiters(io) == 0) {
            last = now;
            still_since = Io.Clock.awake.now(io);
        } else if (elapsedSince(io, still_since).toMilliseconds() >= 300) {
            break;
        }
        if (elapsedSince(io, start).toSeconds() >= 20) return error.TestPublishNeverWaited;
    }

    const closing = Io.Clock.awake.now(io);
    client.close();
    try testing.expectError(error.ConnectionClosed, publisher.await(io));
    try testing.expect(elapsedSince(io, closing).toSeconds() < 1);
    // As it was, for the tests after this one.
    try e2e.unpause(e2e.servers.stall_container);
}

test "close() while a publish waits for room, the server not reading: ConnectionClosed at once" {
    try e2e.onZio(closeDuringStalledPublish);
}

/// Publishes one HPUB with `block` as its header block from a connection
/// of its own, as another client could: the server passes the block on
/// unchecked.
fn publishRaw(io: Io, block: []const u8, payload: []const u8) !void {
    const address: Io.net.IpAddress = try .parseIp4("127.0.0.1", 14222);
    const stream = try address.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var read_buffer: [4096]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    var write_buffer: [1024]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    const w = &writer.interface;
    try w.writeAll("CONNECT {\"verbose\":false,\"pedantic\":false,\"headers\":true,\"protocol\":1}\r\n");
    try w.print("HPUB e2e.garbage {d} {d}\r\n", .{ block.len, block.len + payload.len });
    try w.writeAll(block);
    try w.writeAll(payload);
    try w.writeAll("\r\nPING\r\n");
    try w.flush();
    // INFO, then PONG once the server has the message.
    while (true) {
        const line = try reader.interface.takeDelimiterInclusive('\n');
        if (std.mem.startsWith(u8, line, "PONG")) return;
    }
}

fn garbageHeaders(io: Io) !void {
    var client: nats.Client = try .init(testing.allocator, io, .{ .servers = &.{e2e.servers.plain} });
    defer client.deinit();
    try client.connect();
    const sub = try client.subscribe("e2e.garbage", .{});
    defer sub.deinit();
    try client.flush(.{});
    try publishRaw(io, "garbage line\r\n: no name\r\nX-Id: 1\r\nno colon\r\n\r\n", "whole");
    try client.flush(.{});
    var msg = (try sub.next(within_five_seconds)) orelse return error.TestNoMessage;
    defer msg.deinit();
    try testing.expectEqualStrings("whole", msg.payload);
    try testing.expectEqualStrings("1", msg.headers.get("X-Id").?);
    try testing.expect(msg.status == null);
    try testing.expect(client.isConnected());
}

test "a broken header block from another publisher: the message arrives whole" {
    try e2e.onZio(garbageHeaders);
}

fn maxPayloadBoundary(io: Io) !void {
    var client: nats.Client = try .init(testing.allocator, io, .{ .servers = &.{e2e.servers.plain} });
    defer client.deinit();
    try client.connect();
    const max: usize = max: {
        const info = (try client.serverInfo(testing.allocator)) orelse return error.TestNoInfo;
        defer info.deinit();
        break :max @intCast(info.value.max_payload);
    };
    const sub = try client.subscribe("e2e.max", .{});
    defer sub.deinit();
    try client.flush(.{});
    // A block of 18 bytes; the server counts it with the payload.
    const headers: []const nats.Header = &.{.{ .name = "A", .value = "b" }};
    const payload = try testing.allocator.alloc(u8, max - 18 + 1);
    defer testing.allocator.free(payload);
    @memset(payload, 'm');
    try client.publishMessage(.{ .subject = "e2e.max", .headers = headers, .payload = payload[0 .. max - 18] });
    try testing.expectError(error.PayloadTooLarge, client.publishMessage(.{ .subject = "e2e.max", .headers = headers, .payload = payload }));
    try client.flush(.{});
    try testing.expect(client.isConnected());
    var msg = (try sub.next(within_five_seconds)) orelse return error.TestNoMessage;
    defer msg.deinit();
    try testing.expectEqual(max - 18, msg.payload.len);
    try testing.expectEqualStrings("b", msg.headers.get("A").?);
}

test "headers and payload exactly at the server's max_payload pass, a byte more is PayloadTooLarge" {
    try e2e.onZio(maxPayloadBoundary);
}

fn controlLineBoundary(io: Io) !void {
    var client: nats.Client = try .init(testing.allocator, io, .{ .servers = &.{e2e.servers.plain} });
    defer client.deinit();
    try client.connect();
    var subject: [4095]u8 = @splat('s');
    subject[0] = 'p';
    // SUB <subject> 1 and PUB <subject> 0: 4094 + 1 + 1 = 4096 bytes of
    // arguments, the server's max_control_line.
    const sub = try client.subscribe(subject[0..4094], .{});
    defer sub.deinit();
    try client.flush(.{});
    try client.publish(subject[0..4094], "");
    try client.flush(.{});
    try testing.expect(client.isConnected());
    var msg = (try sub.next(within_five_seconds)) orelse return error.TestNoMessage;
    msg.deinit();
    // One byte more never goes out: the server would close the connection.
    try testing.expectError(error.InvalidSubject, client.publish(&subject, ""));
    try testing.expectError(error.InvalidSubject, client.subscribe(&subject, .{}));
    try client.flush(.{});
    try testing.expect(client.isConnected());
}

test "4096 bytes of arguments pass the server, one more is InvalidSubject" {
    try e2e.onZio(controlLineBoundary);
}

fn refusedQueueSubscription(io: Io) !void {
    var client: nats.Client = try .init(testing.allocator, io, .{
        .servers = &.{e2e.servers.auth},
        .auth = .{ .user_password = .{ .username = "limited", .password = "limited" } },
    });
    defer client.deinit();
    try client.connect();
    // The server names the queue group too, quoted with escapes.
    const grouped = try client.subscribe("forbidden", .{ .queue = "g\"q" });
    defer grouped.deinit();
    const allowed = try client.subscribe("e2e.queue.allowed", .{ .queue = "g\"q" });
    defer allowed.deinit();
    try testing.expectError(error.PermissionDenied, grouped.next(within_five_seconds));
    try client.publish("e2e.queue.allowed", "fine");
    try client.flush(.{});
    try expectMessage(allowed, "e2e.queue.allowed", "fine");
}

test "a refused queue subscription gives PermissionDenied" {
    try e2e.onZio(refusedQueueSubscription);
}

fn unsubscribeStopsDelivery(io: Io) !void {
    var client: nats.Client = try .init(testing.allocator, io, .{ .servers = &.{e2e.servers.plain} });
    defer client.deinit();
    try client.connect();
    const sub = try client.subscribe("e2e.unsub", .{});
    defer sub.deinit();
    try client.flush(.{});
    try client.publish("e2e.unsub", "1");
    try client.flush(.{});
    try expectMessage(sub, "e2e.unsub", "1");
    try sub.unsubscribe();
    try client.publish("e2e.unsub", "2");
    try client.flush(.{});
    try testing.expect(try sub.next(within_five_seconds) == null);
    try testing.expectEqual(1, sub.stats().received);
    // Unsubscribing again changes nothing.
    try sub.unsubscribe();
}

test "unsubscribe() stops the delivery" {
    try e2e.onZio(unsubscribeStopsDelivery);
}

fn unsubscribeDuringNext(io: Io) !void {
    var client: nats.Client = try .init(testing.allocator, io, .{ .servers = &.{e2e.servers.plain} });
    defer client.deinit();
    try client.connect();
    const idle = try client.subscribe("e2e.unsub.idle", .{});
    defer idle.deinit();
    var receiver = try io.concurrent(nextLong, .{idle});
    defer _ = receiver.cancel(io) catch null;
    try awaitReceiving(io, idle);
    const start = Io.Clock.awake.now(io);
    try idle.unsubscribe();
    try testing.expect(try receiver.await(io) == null);
    try testing.expect(elapsedSince(io, start).toSeconds() < 1);
    try client.flush(.{});
    try testing.expect(client.isConnected());
}

test "unsubscribe() from another task while next() waits: null at once" {
    try e2e.onZio(unsubscribeDuringNext);
}
