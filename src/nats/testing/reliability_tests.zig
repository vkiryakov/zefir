//! The pool of servers, reconnect, lame duck, refused credentials, drain,
//! events and statistics against fake servers on loopback. Each test starts
//! its own server function in a task and cancels it on the way out; the
//! client's waits are bounded, so a mistake fails a test instead of hanging
//! it.

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

/// The server's side of the handshake with `info` as its INFO.
fn handshake(peer: *FakeServer.Peer, info: []const u8) !void {
    try peer.send(info);
    const connect_line = try peer.readLine();
    if (!std.mem.startsWith(u8, connect_line, "CONNECT {")) return error.TestNotConnect;
    try peer.expectLine("PING");
    try peer.send(golden.pong);
}

/// Answers every PING until the client hangs up.
fn answerPings(peer: *FakeServer.Peer) !void {
    while (try peer.nextLine()) |line| {
        if (std.mem.eql(u8, line, "PING")) try peer.send(golden.pong);
    }
}

/// Node A of a cluster announces itself and 14235; at the client's next
/// PING, 14235 has left the cluster.
fn serveCluster(io: Io, listener: *net.Server) !void {
    var peer: FakeServer.Peer = undefined;
    try peer.accept(io, listener);
    defer peer.close();
    try handshake(&peer, "INFO " ++ golden.info_cluster_json ++ " \r\n");
    try peer.expectLine("PING");
    try peer.send("INFO {\"server_id\":\"A\",\"proto\":1,\"headers\":true,\"connect_urls\":[\"127.0.0.1:14234\"]} \r\n" ++ golden.pong);
    try answerPings(&peer);
}

test "the servers a cluster announces join the pool, and leave it when no longer announced" {
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var server = try io.concurrent(serveCluster, .{ io, &listener });
    defer server.cancel(io) catch {};
    var url: [64]u8 = undefined;
    var client: Client = try .init(testing.allocator, io, .{ .servers = &.{try FakeServer.url(&listener, &url)}, .randomize_servers = false });
    defer client.deinit();
    try client.connect();

    var buffer: [8]nats.ServerAddress = undefined;
    const announced = client.discoveredServers(&buffer);
    try testing.expectEqual(2, announced.len);
    try testing.expectEqual(14234, announced[0].port);
    try testing.expectEqual(14235, announced[1].port);
    // The INFO that drops 14235 comes before the PONG of this flush.
    try client.flush(quick);
    const left = client.discoveredServers(&buffer);
    try testing.expectEqual(1, left.len);
    try testing.expectEqual(14234, left[0].port);
    client.close();
    try server.await(io);
}

test "ignore_discovered_servers keeps the pool to the servers of the options" {
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var server = try io.concurrent(serveCluster, .{ io, &listener });
    defer server.cancel(io) catch {};
    var url: [64]u8 = undefined;
    var client: Client = try .init(testing.allocator, io, .{ .servers = &.{try FakeServer.url(&listener, &url)}, .ignore_discovered_servers = true });
    defer client.deinit();
    try client.connect();
    try client.flush(quick);
    var buffer: [8]nats.ServerAddress = undefined;
    try testing.expectEqual(0, client.discoveredServers(&buffer).len);
    client.close();
    try server.await(io);
}

/// What a fake server saw of its connections: every line a client sent,
/// a PUB's payload on a line of its own, and `--` between connections.
const Record = struct {
    mutex: Io.Mutex = .init,
    text: std.ArrayList(u8) = .empty,
    /// Connections accepted.
    accepted: std.atomic.Value(u32) = .init(0),

    fn note(r: *Record, io: Io, line: []const u8) !void {
        r.mutex.lockUncancelable(io);
        defer r.mutex.unlock(io);
        try r.text.appendSlice(testing.allocator, line);
        try r.text.append(testing.allocator, '\n');
    }

    /// What was seen so far; the caller frees it.
    fn seen(r: *Record, io: Io) ![]u8 {
        r.mutex.lockUncancelable(io);
        defer r.mutex.unlock(io);
        return testing.allocator.dupe(u8, r.text.items);
    }

    fn deinit(r: *Record) void {
        r.text.deinit(testing.allocator);
    }
};

/// What a fake server does with one connection; the connection closes
/// when it returns.
const Session = *const fn (peer: *FakeServer.Peer, record: *Record) anyerror!void;

/// Plays `sessions` on the connections that come, one each, in turn.
fn serveSessions(io: Io, listener: *net.Server, sessions: []const Session, record: *Record) anyerror!void {
    for (sessions) |session| {
        var peer: FakeServer.Peer = undefined;
        try peer.accept(io, listener);
        defer peer.close();
        _ = record.accepted.fetchAdd(1, .monotonic);
        if (record.accepted.load(.monotonic) > 1) try record.note(io, "--");
        try session(&peer, record);
    }
}

/// The next frame the client sent, noted: a line, and a PUB's or HPUB's
/// payload after it. Null when the client hung up.
fn nextFrame(peer: *FakeServer.Peer, record: *Record) !?[]const u8 {
    const line = (try peer.nextLine()) orelse return null;
    try record.note(peer.io, line);
    if (std.mem.startsWith(u8, line, "PUB ") or std.mem.startsWith(u8, line, "HPUB ")) {
        const size = try std.fmt.parseInt(usize, line[std.mem.findScalarLast(u8, line, ' ').? + 1 ..], 10);
        var body: [256]u8 = undefined;
        if (size + 2 > body.len) return error.TestPayloadTooLong;
        try peer.readExact(body[0 .. size + 2]);
        try record.note(peer.io, body[0..size]);
        return "PUB";
    }
    return line;
}

/// Notes frames until one starts with `prefix`; false when the client hung
/// up first.
fn readUntil(peer: *FakeServer.Peer, record: *Record, prefix: []const u8) !bool {
    while (try nextFrame(peer, record)) |frame| {
        if (std.mem.startsWith(u8, frame, prefix)) return true;
    }
    return false;
}

/// The handshake, then every frame noted and every PING answered until the
/// client hangs up.
fn sessionServe(peer: *FakeServer.Peer, record: *Record) anyerror!void {
    try handshake(peer, golden.info_default);
    while (try nextFrame(peer, record)) |frame| {
        if (std.mem.eql(u8, frame, "PING")) try peer.send(golden.pong);
    }
}

/// Takes the connection and closes it before INFO: a failed attempt.
fn sessionRefuse(peer: *FakeServer.Peer, record: *Record) anyerror!void {
    _ = peer;
    _ = record;
}

/// The handshake, then a hang-up at once.
fn sessionHangUp(peer: *FakeServer.Peer, record: *Record) anyerror!void {
    _ = record;
    try handshake(peer, golden.info_default);
}

/// Two messages for the subscription to `bar`, then a hang-up at the
/// client's next PING.
fn sessionTwoThenHangUp(peer: *FakeServer.Peer, record: *Record) anyerror!void {
    try handshake(peer, golden.info_default);
    if (!try readUntil(peer, record, "SUB bar ")) return error.TestNoSub;
    try peer.send("MSG bar 2 1\r\na\r\nMSG bar 2 1\r\nb\r\n");
    if (!try readUntil(peer, record, "PING")) return error.TestNoPing;
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

const within_five_seconds: nats.ReceiveOptions = .{ .timeout = .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } } };

fn expectMessage(sub: *nats.Subscription, payload: []const u8) !void {
    var msg = (try sub.next(within_five_seconds)) orelse return error.TestNoMessage;
    defer msg.deinit();
    try testing.expectEqualStrings(payload, msg.payload);
}

fn requestLong(client: *Client) Client.RequestError!nats.Message {
    return client.request("service.x", "?", .{ .timeout = .{ .duration = .{ .raw = .fromSeconds(30), .clock = .awake } } });
}

fn releaseReply(result: Client.RequestError!nats.Message) void {
    var reply = result catch return;
    reply.deinit();
}

/// Waits until `count` requests wait for replies, for 5 s at most.
fn awaitAwaiting(client: *Client, count: u32) !void {
    const io = client.io;
    const give_up = time.after(io, .fromSeconds(5));
    while (client.inbox.awaitingCount(io) < count) {
        if (time.expired(io, give_up)) return error.TestRequestNeverWaited;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}

test "a lost connection: the client reconnects and subscribes again with the same SIDs, the inbox too" {
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var record: Record = .{};
    defer record.deinit();
    const sessions = [_]Session{ sessionTwoThenHangUp, sessionServe };
    var server = try io.concurrent(serveSessions, .{ io, &listener, &sessions, &record });
    defer server.cancel(io) catch {};
    var url: [64]u8 = undefined;
    var client: Client = try .init(testing.allocator, io, .{ .servers = &.{try FakeServer.url(&listener, &url)} });
    defer client.deinit();
    try client.connect();

    const foo = try client.subscribe("foo", .{});
    defer foo.deinit();
    const bar = try client.subscribe("bar", .{ .max_messages = 5 });
    defer bar.deinit();
    var request = try io.concurrent(requestLong, .{&client});
    defer releaseReply(request.cancel(io));
    try awaitAwaiting(&client, 1);
    try expectMessage(bar, "a");
    try expectMessage(bar, "b");
    // The server hangs up at this PING: the flush and the waiting request
    // learn it at once.
    try testing.expectError(error.Disconnected, client.flush(quick));
    if (request.await(io)) |_| return error.TestUnexpectedReply else |err| try testing.expectEqual(error.Disconnected, err);

    try awaitState(&client, .connected);
    try client.publish("after", "x");
    try client.flush(quick);
    client.close();
    try server.await(io);

    const seen = try record.seen(io);
    defer testing.allocator.free(seen);
    const second = seen[std.mem.find(u8, seen, "--\n").? + 3 ..];
    // SUBs with their SIDs, the inbox's, then what max_messages leaves;
    // then the new frames.
    var lines = std.mem.splitScalar(u8, second, '\n');
    try testing.expectEqualStrings("SUB foo 1", lines.next().?);
    try testing.expectEqualStrings("SUB bar 2", lines.next().?);
    const inbox_sub = lines.next().?;
    try testing.expect(std.mem.startsWith(u8, inbox_sub, "SUB _INBOX.") and std.mem.endsWith(u8, inbox_sub, ".* 3"));
    try testing.expectEqualStrings("UNSUB 2 3", lines.next().?);
    try testing.expectEqualStrings("PUB after 1", lines.next().?);
    try testing.expectEqualStrings("x", lines.next().?);
    try testing.expectEqualStrings("PING", lines.next().?);
    // The inbox kept its subject.
    try testing.expect(std.mem.find(u8, seen[0 .. seen.len - second.len], inbox_sub) != null);
}

/// Waits until the server accepted `count` connections, for 5 s at most.
fn awaitAccepted(record: *Record, count: u32) !void {
    const give_up = time.after(testing.io, .fromSeconds(5));
    while (record.accepted.load(.monotonic) < count) {
        if (time.expired(testing.io, give_up)) return error.TestNeverAccepted;
        try testing.io.sleep(.fromMilliseconds(1), .awake);
    }
}

const fast_reconnect: nats.ReconnectOptions = .{ .min_delay = .fromMilliseconds(1), .max_delay = .fromMilliseconds(5) };

test "after max_attempts failed attempts in a row the client gives up and closes" {
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var record: Record = .{};
    defer record.deinit();
    const sessions = [_]Session{ sessionHangUp, sessionRefuse, sessionRefuse, sessionRefuse, sessionServe };
    var server = try io.concurrent(serveSessions, .{ io, &listener, &sessions, &record });
    defer server.cancel(io) catch {};
    var url: [64]u8 = undefined;
    var reconnect = fast_reconnect;
    reconnect.max_attempts = 3;
    var client: Client = try .init(testing.allocator, io, .{ .servers = &.{try FakeServer.url(&listener, &url)}, .reconnect = reconnect });
    defer client.deinit();
    try client.connect();
    try awaitState(&client, .closed);
    try testing.expectError(error.ConnectionClosed, client.publish("foo", "x"));
    // The connection, then three attempts; the fifth session never comes.
    try testing.expectEqual(4, record.accepted.load(.monotonic));
}

fn sessionEarly(peer: *FakeServer.Peer, record: *Record) anyerror!void {
    try handshake(peer, golden.info_default);
    if (!try readUntil(peer, record, "SUB early 1")) return error.TestNoSub;
    try peer.send("MSG early 1 2\r\nhi\r\n");
    try answerPings(peer);
}

test "retry_initial_connect: connect() returns at once, and the client connects in the background" {
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var record: Record = .{};
    defer record.deinit();
    const sessions = [_]Session{ sessionRefuse, sessionRefuse, sessionEarly };
    var server = try io.concurrent(serveSessions, .{ io, &listener, &sessions, &record });
    defer server.cancel(io) catch {};
    var url: [64]u8 = undefined;
    var client: Client = try .init(testing.allocator, io, .{
        .servers = &.{try FakeServer.url(&listener, &url)},
        .retry_initial_connect = true,
        .reconnect = fast_reconnect,
    });
    defer client.deinit();
    try client.connect();
    // A subscription made before the first connection goes out with it.
    const early = try client.subscribe("early", .{});
    defer early.deinit();
    try expectMessage(early, "hi");
    try testing.expectEqual(.connected, client.state());
    try testing.expectEqual(3, record.accepted.load(.monotonic));
    client.close();
    try server.await(io);
}

test "with retry_initial_connect, close() stops the attempts at once" {
    const io = testing.io;
    // A port nobody listens on.
    var gone = try FakeServer.listen(io);
    var url: [64]u8 = undefined;
    const dead = try FakeServer.url(&gone, &url);
    gone.deinit(io);
    var client: Client = try .init(testing.allocator, io, .{ .servers = &.{dead}, .retry_initial_connect = true });
    defer client.deinit();
    try client.connect();
    try testing.expectEqual(.reconnecting, client.state());
    try testing.expectError(error.Disconnected, client.flush(quick));
    // The backoff has grown by now; close() does not wait for it.
    try io.sleep(.fromMilliseconds(600), .awake);
    const start = Io.Clock.awake.now(io);
    client.close();
    try testing.expectEqual(.closed, client.state());
    try testing.expect(start.durationTo(Io.Clock.awake.now(io)).toMilliseconds() < 500);
}
