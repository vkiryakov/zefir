//! The subscriber against the servers that REDIS_IMAGE names: the
//! messages of a channel and of a pattern as PUBLISH sends them, one of
//! 1 MiB whole; a subscriber that does not read, which the server closes
//! past its client-output-buffer-limit; a paused server, which leaves the
//! subscriber's PING without a reply; a restarted one, which drops its
//! connection; and the client's close, after which `next` returns null.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const redis = @import("redis");
const cmd = redis.cmd;
const e2e = @import("root.zig");
const within = e2e.within;

/// A client of the server at `port`, connected; `buffer` holds its URL.
fn connectedTo(io: Io, client: *redis.Client, port: u16, buffer: []u8) !void {
    client.* = try .init(testing.allocator, io, .{ .url = try std.fmt.bufPrint(buffer, "redis://127.0.0.1:{d}", .{port}) });
    errdefer client.deinit();
    var d: redis.Diagnostics = .{};
    client.connect(io, within(io, .fromSeconds(10)).ctx, &d) catch |err| {
        std.debug.print("connect: {t}: {s}\n", .{ err, d.message() });
        return err;
    };
}

/// A subscriber of `client` by `options`, which must subscribe.
fn subscribed(io: Io, client: *redis.Client, options: redis.SubscribeOptions) !redis.Subscriber {
    var d: redis.Diagnostics = .{};
    var with = options;
    with.diagnostics = &d;
    return client.subscribe(io, within(io, .fromSeconds(10)), with) catch |err| {
        std.debug.print("subscribe: {t}: {s}\n", .{ err, d.message() });
        return err;
    };
}

/// PUBLISH of `payload` to `channel` through `client`: how many
/// subscribers got it.
fn publish(io: Io, client: *redis.Client, channel: []const u8, payload: []const u8) !u64 {
    var d: redis.Diagnostics = .{};
    return client.run(io, within(io, .fromSeconds(10)), cmd.publish(channel, payload), .{ .diagnostics = &d }) catch |err| {
        std.debug.print("publish: {t}: {s}\n", .{ err, d.message() });
        return err;
    };
}

/// The next message of `sub`, which must come: one of `channel`, by
/// `pattern` when not null.
fn nextMessage(io: Io, sub: *redis.Subscriber, channel: []const u8, pattern: ?[]const u8) !redis.Subscriber.Message {
    const message = sub.next(io) catch |err| {
        std.debug.print("next: {t}: {s}\n", .{ err, sub.diagnostics().message() });
        return err;
    } orelse return error.TestExpectedMessage;
    try testing.expectEqualStrings(channel, message.channel);
    try testing.expectEqualDeep(pattern, message.pattern);
    return message;
}

test "the messages of a channel and of a pattern come as PUBLISH sends them, which counts the subscriber; a payload comes byte for byte, one of 1 MiB whole" {
    try e2e.onZio(messages);
}

fn messages(io: Io) !void {
    var s: e2e.Session = undefined;
    try s.open(io);
    defer s.close();
    var sub = try subscribed(io, &s.client, .{ .channels = &.{"e2e:pubsub:orders"}, .patterns = &.{"e2e:pubsub:events.*"} });
    defer sub.close(io);
    try testing.expectEqual(@as(usize, 1), s.client.stats().subscribers);

    try testing.expectEqual(@as(u64, 1), try s.run(cmd.publish("e2e:pubsub:orders", "new")));
    try testing.expectEqualStrings("new", (try nextMessage(io, &sub, "e2e:pubsub:orders", null)).payload);
    try testing.expectEqual(@as(u64, 1), try s.run(cmd.publish("e2e:pubsub:events.paid", "a\r\nb\x00c")));
    try testing.expectEqualStrings("a\r\nb\x00c", (try nextMessage(io, &sub, "e2e:pubsub:events.paid", "e2e:pubsub:events.*")).payload);

    const big = try testing.allocator.alloc(u8, 1024 * 1024);
    defer testing.allocator.free(big);
    for (big, 0..) |*b, i| b.* = @truncate(i *% 31);
    try testing.expectEqual(@as(u64, 1), try s.run(cmd.publish("e2e:pubsub:orders", big)));
    try testing.expect(std.mem.eql(u8, big, (try nextMessage(io, &sub, "e2e:pubsub:orders", null)).payload));
}

/// `CONFIG SET client-output-buffer-limit <limit>` on the server of
/// `client`.
fn outputLimit(io: Io, client: *redis.Client, limit: []const u8) !void {
    var d: redis.Diagnostics = .{};
    client.run(io, within(io, .fromSeconds(10)), cmd.raw(void, .{ "CONFIG", "SET", "client-output-buffer-limit", limit }), .{ .diagnostics = &d }) catch |err| {
        std.debug.print("CONFIG SET client-output-buffer-limit {s}: {t}: {s}\n", .{ limit, err, d.message() });
        return err;
    };
}

test "a subscriber that reads nothing while the server holds more than its client-output-buffer-limit for it is closed: the messages before come, then ConnectionLost" {
    try e2e.onZio(slow);
}

fn slow(io: Io) !void {
    // On redis-restart, which its own scenario restarts: a run that dies
    // here leaves the lower limit only until then.
    var client: redis.Client = undefined;
    var buffer: [64]u8 = undefined;
    try connectedTo(io, &client, e2e.servers.restart_port, &buffer);
    defer client.deinit();
    try outputLimit(io, &client, "pubsub 1mb 1mb 0");
    // The limit of Redis and Valkey.
    defer outputLimit(io, &client, "pubsub 32mb 8mb 60") catch {};
    var sub = try subscribed(io, &client, .{ .channels = &.{"e2e:pubsub:slow"} });
    defer sub.close(io);

    // 64 MiB while the subscriber reads nothing: far more than the sockets
    // between them hold, the ports of docker included, so the server keeps
    // more than 1 MiB for the subscriber, and drops it. Valkey may count
    // it in PUBLISH until its socket drains.
    const chunk = try testing.allocator.alloc(u8, 256 * 1024);
    defer testing.allocator.free(chunk);
    @memset(chunk, 'x');
    const sent = 256;
    for (0..sent) |_| _ = try publish(io, &client, "e2e:pubsub:slow", chunk);
    // What the sockets held comes, then the end of the stream.
    var got: usize = 0;
    while (true) {
        const message = sub.next(io) catch |err| {
            try testing.expectEqual(error.ConnectionLost, err);
            break;
        } orelse return error.TestUnexpectedResult;
        try testing.expectEqual(chunk.len, message.payload.len);
        got += 1;
        if (got == sent) {
            std.debug.print("the server sent all of 64 MiB to a subscriber that read none of it as it came\n", .{});
            return error.TestUnexpectedResult;
        }
    }
    try testing.expect(std.mem.indexOf(u8, sub.diagnostics().message(), "a subscriber that falls behind") != null);
    try testing.expectError(error.Closed, sub.next(io));
}

test "a paused server leaves the subscriber's PING without a reply: ConnectionLost within about twice idle_ping" {
    try e2e.onZio(paused);
}

fn paused(io: Io) !void {
    var client: redis.Client = undefined;
    var buffer: [64]u8 = undefined;
    try connectedTo(io, &client, e2e.servers.stall_port, &buffer);
    defer client.deinit();
    var sub = try subscribed(io, &client, .{ .channels = &.{"e2e:pubsub:stall"}, .idle_ping = .fromMilliseconds(500) });
    defer sub.close(io);

    try e2e.docker(&.{ "pause", e2e.servers.stall_container });
    defer e2e.unpause(e2e.servers.stall_container) catch {};
    const start = Io.Clock.awake.now(io);
    try testing.expectError(error.ConnectionLost, sub.next(io));
    const took = start.durationTo(Io.Clock.awake.now(io)).toMilliseconds();
    if (took < 900 or took >= 3000) {
        std.debug.print("ConnectionLost of a paused server came after {d} ms\n", .{took});
        return error.TestUnexpectedResult;
    }
    try testing.expect(std.mem.endsWith(u8, sub.diagnostics().message(), " after the subscriber's PING"));
}

test "a restarted server drops the subscriber's connection: ConnectionLost, then Closed" {
    try e2e.onZio(restarted);
}

fn restarted(io: Io) !void {
    var client: redis.Client = undefined;
    var buffer: [64]u8 = undefined;
    try connectedTo(io, &client, e2e.servers.restart_port, &buffer);
    defer client.deinit();
    // A short idle_ping, should the end of the stream not come through the
    // ports of docker: the PING finds the connection gone.
    var sub = try subscribed(io, &client, .{ .channels = &.{"e2e:pubsub:restart"}, .idle_ping = .fromSeconds(1) });
    defer sub.close(io);

    try e2e.restart(e2e.servers.restart_container);
    try testing.expectError(error.ConnectionLost, sub.next(io));
    try testing.expectError(error.Closed, sub.next(io));
}

/// `sub.next` from a task of its own.
fn nextOf(sub: *redis.Subscriber, io: Io) redis.Error!?redis.Subscriber.Message {
    return sub.next(io);
}

test "the client's close ends a subscriber that waits in next: null" {
    try e2e.onZio(clientCloses);
}

fn clientCloses(io: Io) !void {
    var s: e2e.Session = undefined;
    try s.open(io);
    defer s.close();
    var sub = try subscribed(io, &s.client, .{ .channels = &.{"e2e:pubsub:close"} });
    defer sub.close(io);
    var reading = try io.concurrent(nextOf, .{ &sub, io });
    defer if (reading.cancel(io)) |_| {} else |_| {};
    // Long enough for next to wait on the socket.
    try io.sleep(.fromMilliseconds(100), .awake);
    s.client.close(io);
    try testing.expectEqual(@as(?redis.Subscriber.Message, null), try reading.await(io));
}
