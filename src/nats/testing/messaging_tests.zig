//! Publishing and subscribing against a fake server on loopback. Each test
//! starts its own server function in a task and cancels it on the way out;
//! the client's waits are bounded, so a mistake fails a test instead of
//! hanging it.

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

const info_without_headers = "INFO {\"server_id\":\"old\",\"proto\":1,\"max_payload\":1048576} \r\n";
const info_small = "INFO {\"server_id\":\"small\",\"proto\":1,\"headers\":true,\"max_payload\":1024} \r\n";
const info_no_limit = "INFO {\"server_id\":\"no-limit\",\"proto\":1,\"headers\":true} \r\n";
const info_zero_limit = "INFO {\"server_id\":\"zero\",\"proto\":1,\"headers\":true,\"max_payload\":0} \r\n";
const info_huge = "INFO {\"server_id\":\"huge\",\"proto\":1,\"headers\":true,\"max_payload\":67108864} \r\n";

/// The server's side of the handshake, with `info` as its INFO.
fn handshake(peer: *FakeServer.Peer, info: []const u8) !void {
    try peer.send(info);
    const connect_line = try peer.readLine();
    if (!std.mem.startsWith(u8, connect_line, "CONNECT {")) return error.TestNotConnect;
    try peer.expectLine("PING");
    try peer.send(golden.pong);
}

/// After the handshake, writes every frame the client sends to
/// `transcript`, payloads included, and answers each PING, until the
/// client hangs up.
fn serveRecording(io: Io, listener: *net.Server, info: []const u8, transcript: *std.ArrayList(u8)) !void {
    var peer: FakeServer.Peer = undefined;
    try peer.accept(io, listener);
    defer peer.close();
    try handshake(&peer, info);
    while (try peer.nextLine()) |line| {
        try transcript.appendSlice(testing.allocator, line);
        try transcript.appendSlice(testing.allocator, "\r\n");
        if (std.mem.eql(u8, line, "PING")) {
            try peer.send(golden.pong);
        } else if (std.mem.startsWith(u8, line, "PUB ") or std.mem.startsWith(u8, line, "HPUB ")) {
            const size = try std.fmt.parseInt(usize, line[std.mem.findScalarLast(u8, line, ' ').? + 1 ..], 10);
            const body = try testing.allocator.alloc(u8, size + 2);
            defer testing.allocator.free(body);
            try peer.readExact(body);
            try transcript.appendSlice(testing.allocator, body);
        }
    }
}

/// A client connected to a recording server, and what the server recorded.
const Recorded = struct {
    listener: net.Server,
    server: Io.Future(anyerror!void),
    transcript: std.ArrayList(u8) = .empty,
    url: [64]u8 = undefined,
    client: Client,

    /// Starts the server with `info` and connects a client with `options`
    /// (its servers are replaced by the fake one). Initialize in place.
    fn start(r: *Recorded, info: []const u8, options: nats.Options) !void {
        const io = testing.io;
        r.listener = try FakeServer.listen(io);
        errdefer r.listener.deinit(io);
        r.transcript = .empty;
        errdefer r.transcript.deinit(testing.allocator);
        r.server = try io.concurrent(serveRecordingAny, .{ io, &r.listener, info, &r.transcript });
        errdefer r.server.cancel(io) catch {};
        var with_server = options;
        with_server.servers = &.{try FakeServer.url(&r.listener, &r.url)};
        r.client = try .init(testing.allocator, io, with_server);
        errdefer r.client.deinit();
        try r.client.connect();
    }

    /// Flushes, closes the client and waits for the server; then
    /// `transcript` holds everything the client sent.
    fn finish(r: *Recorded) !void {
        try r.client.flush(quick);
        r.client.close();
        try r.server.await(testing.io);
    }

    fn deinit(r: *Recorded) void {
        const io = testing.io;
        r.client.deinit();
        r.server.cancel(io) catch {};
        r.listener.deinit(io);
        r.transcript.deinit(testing.allocator);
    }
};

fn serveRecordingAny(io: Io, listener: *net.Server, info: []const u8, transcript: *std.ArrayList(u8)) anyerror!void {
    return serveRecording(io, listener, info, transcript);
}

test "publish sends PUB; a reply subject and headers go along" {
    var r: Recorded = undefined;
    try r.start(golden.info_default, .{ .servers = &.{} });
    defer r.deinit();
    try r.client.publish("foo", "hello");
    try r.client.publishMessage(.{ .subject = "foo", .reply_to = "reply.to", .payload = "x" });
    try r.client.publishMessage(.{
        .subject = "h",
        .headers = &.{ .{ .name = "X-A", .value = "1" }, .{ .name = "X-A", .value = "2" } },
        .payload = "p",
    });
    try r.client.publishMessage(.{ .subject = "h.only", .reply_to = "r", .headers = &.{.{ .name = "K", .value = "v" }} });
    // A binary payload, with bytes that look like frames.
    try r.client.publish("bin", "\r\nPING\r\n\x00\xff");
    try r.finish();
    try testing.expectEqualStrings("PUB foo 5\r\nhello\r\n" ++
        "PUB foo reply.to 1\r\nx\r\n" ++
        "HPUB h 28 29\r\nNATS/1.0\r\nX-A: 1\r\nX-A: 2\r\n\r\np\r\n" ++
        "HPUB h.only r 18 18\r\nNATS/1.0\r\nK: v\r\n\r\n\r\n" ++
        "PUB bin 10\r\n\r\nPING\r\n\x00\xff\r\n" ++
        "PING\r\n", r.transcript.items);
}

test "publish refuses bad subjects and headers before anything is queued" {
    var r: Recorded = undefined;
    try r.start(golden.info_default, .{ .servers = &.{} });
    defer r.deinit();
    const c = &r.client;
    for ([_][]const u8{ "", "foo bar", "foo.*", "foo.>", "foo..bar", "foo\r\nPUB x 1" }) |subject| {
        try testing.expectError(error.InvalidSubject, c.publish(subject, "x"));
    }
    try testing.expectError(error.InvalidSubject, c.publishMessage(.{ .subject = "foo", .reply_to = "a b" }));
    try testing.expectError(error.InvalidSubject, c.publishMessage(.{ .subject = "foo", .reply_to = "" }));
    try testing.expectError(error.InvalidHeader, c.publishMessage(.{ .subject = "foo", .headers = &.{.{ .name = "Bad:Name", .value = "v" }} }));
    try testing.expectError(error.InvalidHeader, c.publishMessage(.{ .subject = "foo", .headers = &.{.{ .name = "X", .value = "a\r\nInjected: 1" }} }));
    try r.finish();
    try testing.expectEqualStrings("PING\r\n", r.transcript.items);
}

test "headers need a server that announced them" {
    var r: Recorded = undefined;
    try r.start(info_without_headers, .{ .servers = &.{} });
    defer r.deinit();
    try testing.expectError(error.UnsupportedFeature, r.client.publishMessage(.{ .subject = "foo", .headers = &.{.{ .name = "X", .value = "1" }} }));
    try r.client.publish("foo", "plain");
    try r.finish();
    try testing.expectEqualStrings("PUB foo 5\r\nplain\r\nPING\r\n", r.transcript.items);
}

test "headers and payload up to max_payload pass, a byte more is PayloadTooLarge" {
    var r: Recorded = undefined;
    try r.start(info_small, .{ .servers = &.{} });
    defer r.deinit();
    const payload: [1025]u8 = @splat('x');
    try r.client.publish("big", payload[0..1024]);
    try testing.expectError(error.PayloadTooLarge, r.client.publish("big", &payload));
    // The header block counts too: 18 bytes of it, 1006 of payload.
    const one: []const nats.Header = &.{.{ .name = "A", .value = "b" }};
    try r.client.publishMessage(.{ .subject = "big", .headers = one, .payload = payload[0..1006] });
    try testing.expectError(error.PayloadTooLarge, r.client.publishMessage(.{ .subject = "big", .headers = one, .payload = payload[0..1007] }));
    try r.finish();
    try testing.expectEqualStrings("PUB big 1024\r\n" ++ payload[0..1024] ++ "\r\n" ++
        "HPUB big 18 1024\r\nNATS/1.0\r\nA: b\r\n\r\n" ++ payload[0..1006] ++ "\r\n" ++
        "PING\r\n", r.transcript.items);
}

test "a server that gives no max_payload, or 0, sets no limit" {
    const payload: [4096]u8 = @splat('y');
    for ([_][]const u8{ info_no_limit, info_zero_limit }) |info| {
        var r: Recorded = undefined;
        try r.start(info, .{ .servers = &.{} });
        defer r.deinit();
        try r.client.publish("s", &payload);
        try r.finish();
        try testing.expectEqualStrings("PUB s 4096\r\n" ++ payload ++ "\r\nPING\r\n", r.transcript.items);
    }
}

test "a line of 4096 argument bytes passes, one more is InvalidSubject" {
    var r: Recorded = undefined;
    try r.start(golden.info_default, .{ .servers = &.{} });
    defer r.deinit();
    const subject: [4095]u8 = @splat('s');
    // PUB <subject> 0: the server counts the subject, a space and a digit.
    try r.client.publish(subject[0..4094], "");
    try testing.expectError(error.InvalidSubject, r.client.publish(&subject, ""));
    // HPUB <subject> r 18 18: the reply subject and both sizes count too.
    const one: []const nats.Header = &.{.{ .name = "A", .value = "b" }};
    try r.client.publishMessage(.{ .subject = subject[0..4088], .reply_to = "r", .headers = one });
    try testing.expectError(error.InvalidSubject, r.client.publishMessage(.{ .subject = subject[0..4089], .reply_to = "r", .headers = one }));
    try r.finish();
    try testing.expectEqualStrings("PUB " ++ subject[0..4094] ++ " 0\r\n\r\n" ++
        "HPUB " ++ subject[0..4088] ++ " r 18 18\r\nNATS/1.0\r\nA: b\r\n\r\n\r\n" ++
        "PING\r\n", r.transcript.items);
}

/// A handshake, then nothing is read until `release` is set: the client's
/// writes back up in the socket.
fn serveStalled(io: Io, listener: *net.Server, release: *Io.Event) !void {
    var peer: FakeServer.Peer = undefined;
    try peer.accept(io, listener);
    defer peer.close();
    try handshake(&peer, info_huge);
    try awaitEvent(io, release);
    _ = try peer.readToEnd();
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

/// Waits until a publish waits for room in the outbound queue, for 5 s at
/// most.
fn awaitRoomWaiter(client: *Client) !void {
    const io = client.io;
    const give_up = time.after(io, .fromSeconds(5));
    while (client.outbound.roomWaiters(io) == 0) {
        if (time.expired(io, give_up)) return error.TestPublishNeverWaited;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}

fn elapsedSince(io: Io, start: Io.Timestamp) Io.Duration {
    return start.durationTo(Io.Clock.awake.now(io));
}

fn publishLate(client: *Client) Client.PublishError!void {
    return client.publish("late", "x");
}

/// A client whose outbound queue is full: the server does not read, and a
/// frame of 16 MiB fills the socket. The next publish waits for room.
const Stalled = struct {
    listener: net.Server,
    release: Io.Event = .unset,
    server: Io.Future(anyerror!void),
    url: [64]u8 = undefined,
    client: Client,
    big: []u8,

    fn start(s: *Stalled) !void {
        const io = testing.io;
        s.listener = try FakeServer.listen(io);
        errdefer s.listener.deinit(io);
        s.release = .unset;
        s.server = try io.concurrent(serveStalledAny, .{ io, &s.listener, &s.release });
        errdefer {
            s.release.set(io);
            s.server.cancel(io) catch {};
        }
        s.client = try .init(testing.allocator, io, .{
            .servers = &.{try FakeServer.url(&s.listener, &s.url)},
            .limits = .{ .outbound_bytes = 1 },
        });
        errdefer s.client.deinit();
        try s.client.connect();
        s.big = try testing.allocator.alloc(u8, 16 * 1024 * 1024);
        errdefer testing.allocator.free(s.big);
        @memset(s.big, 'b');
        // The queue was empty, so this one goes in at once.
        try s.client.publish("big", s.big);
    }

    fn deinit(s: *Stalled) void {
        const io = testing.io;
        s.release.set(io);
        s.client.deinit();
        s.server.cancel(io) catch {};
        s.listener.deinit(io);
        testing.allocator.free(s.big);
    }
};

fn serveStalledAny(io: Io, listener: *net.Server, release: *Io.Event) anyerror!void {
    return serveStalled(io, listener, release);
}

test "a publish that waits for room in the outbound queue can be canceled" {
    const io = testing.io;
    var s: Stalled = undefined;
    try s.start();
    defer s.deinit();
    var publisher = try io.concurrent(publishLate, .{&s.client});
    defer publisher.cancel(io) catch {};
    try awaitRoomWaiter(&s.client);
    try testing.expectError(error.Canceled, publisher.cancel(io));
    try testing.expect(s.client.isConnected());
}

test "close() while a publish waits for room: ConnectionClosed at once" {
    const io = testing.io;
    var s: Stalled = undefined;
    try s.start();
    defer s.deinit();
    var publisher = try io.concurrent(publishLate, .{&s.client});
    defer publisher.cancel(io) catch {};
    try awaitRoomWaiter(&s.client);
    const start = Io.Clock.awake.now(io);
    s.client.close();
    try testing.expectError(error.ConnectionClosed, publisher.await(io));
    try testing.expect(elapsedSince(io, start).toSeconds() < 1);
}
