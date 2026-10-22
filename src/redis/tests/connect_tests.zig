//! Tests of `redis.Client`'s life before its calls: `init` without I/O,
//! `connect` under the caller's deadline and `connect_timeout`, `close`
//! and `deinit`, against `redis.testing.FakeServer` and the server's side
//! played by the test, `FakeServer.Peer`, over loopback. Every test runs
//! under a time limit of 5 s.

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const testing = std.testing;
const core = @import("core");
const redis = @import("../root.zig");
const resp = @import("../resp.zig");
const Client = redis.Client;
const Diagnostics = redis.Diagnostics;
const FakeServer = redis.testing.FakeServer;
const Peer = FakeServer.Peer;
const time = @import("../engine/time.zig");
const replies = @import("hello_replies.zig");
const within5s = @import("time_limit.zig").within5s;
const WindowsLike = @import("windows_like_io.zig").WindowsLike;

fn portOf(peer: *const Peer) u16 {
    return peer.listener.?.socket.address.getPort();
}

fn within(io: Io, duration: Io.Duration) core.Context {
    return core.Context.root.withDeadline(.after(time.now(io), duration));
}

/// Whether a client connects to `peer` within `duration`; one that does is
/// accepted.
fn connectsWithin(io: Io, peer: *Peer, duration: Io.Duration) !bool {
    const Race = union(enum) {
        accepted: anyerror!void,
        timer: Io.Cancelable!void,
    };
    var results: [2]Race = undefined;
    var select: Io.Select(Race) = .init(io, &results);
    try select.concurrent(.accepted, Peer.accept, .{ peer, io });
    select.concurrent(.timer, Io.sleep, .{ io, duration, .awake }) catch |err| {
        while (select.cancel()) |_| {}
        return err;
    };
    const first = try select.await();
    while (select.cancel()) |_| {}
    return switch (first) {
        .accepted => |accepted| {
            try accepted;
            return true;
        },
        .timer => false,
    };
}

/// Plays the server's side of a handshake as Redis 8.10.2: accepts the
/// client, answers HELLO, then CLIENT SETINFO twice.
fn shakeHands(peer: *Peer, io: Io) !void {
    try peer.accept(io);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const hello = (try peer.readCommand(arena.allocator())) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("HELLO", hello[0]);
    try peer.send(replies.redis_8_10_2);
    for (0..2) |_| _ = (try peer.readCommand(arena.allocator())) orelse return error.TestUnexpectedResult;
    try peer.send("+OK\r\n+OK\r\n");
}

test "init opens nothing" {
    try within5s(testing.io, initQuiet, .{testing.io});
}

fn initQuiet(io: Io) !void {
    var peer: Peer = try .listen(io);
    defer peer.close(io);
    var client: Client = try .init(testing.allocator, io, .{ .url = peer.url() });
    defer client.deinit();
    try testing.expect(!try connectsWithin(io, &peer, .fromMilliseconds(100)));
}

test "connect shakes hands with a FakeServer, and a second connect opens nothing" {
    try within5s(testing.io, connectTwice, .{testing.io});
}

fn connectTwice(io: Io) !void {
    {
        var server: FakeServer = try .start(testing.allocator, io, &.{});
        defer server.stop(io);
        var client: Client = try .init(testing.allocator, io, .{ .url = server.url(), .client_name = "api-1" });
        defer client.deinit();
        var d: Diagnostics = .{};
        client.connect(io, within(io, .fromSeconds(5)), &d) catch |err| {
            std.debug.print("{t}: {s}\n", .{ err, d.message() });
            return err;
        };
        defer client.close(io);
        // The handshake is not in the journal, and nothing else came.
        try testing.expectEqual(@as(usize, 0), server.received(io));
        try server.finish(io);
    }
    var peer: Peer = try .listen(io);
    defer peer.close(io);
    var client: Client = try .init(testing.allocator, io, .{ .url = peer.url() });
    defer client.deinit();
    var server = try io.concurrent(shakeHands, .{ &peer, io });
    defer server.cancel(io) catch {};
    try client.connect(io, .root, null);
    try server.await(io);
    try client.connect(io, .root, null);
    try testing.expect(!try connectsWithin(io, &peer, .fromMilliseconds(100)));
}

test "connect while the server refuses connections is Unavailable, and passes once it takes them again" {
    try within5s(testing.io, refusedThenTaken, .{testing.io});
}

/// Sends `GO` to `server` on a connection of its own, which a step of the
/// script answers by refusing connections.
fn goAway(io: Io, server: *const FakeServer) !void {
    const url = server.url();
    const port = try std.fmt.parseInt(u16, url[std.mem.findScalarLast(u8, url, ':').? + 1 ..], 10);
    const address: net.IpAddress = try .parseIp4("127.0.0.1", port);
    const stream = try address.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var buffer: [64]u8 = undefined;
    var writer = stream.writer(io, &buffer);
    try resp.Writer.init(&writer.interface).command(&.{"GO"});
    try writer.interface.flush();
    // The server closes it: the step ran.
    var read_buffer: [64]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    _ = reader.interface.takeByte() catch {};
}

fn refusedThenTaken(io: Io) !void {
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;
    var server: FakeServer = try .start(testing.allocator, io, &.{.expect(.{"GO"}, .refuse_connections)});
    defer server.stop(io);
    try goAway(io, &server);
    var client: Client = try .init(testing.allocator, io, .{ .url = server.url() });
    defer client.deinit();
    var d: Diagnostics = .{};
    try testing.expectError(error.Unavailable, client.connect(io, within(io, .fromSeconds(5)), &d));
    try testing.expectEqual(@as(?Diagnostics.Phase, .handshake), d.phase);
    server.acceptConnections(io);
    try client.connect(io, within(io, .fromSeconds(5)), &d);
    client.close(io);
    try server.finish(io);
}

test "a server that never answers HELLO: the deadline of the call is DeadlineExceeded, connect_timeout Unavailable, and the socket closes either way" {
    try within5s(testing.io, neverAnswers, .{testing.io});
}

/// Accepts the client, reads its HELLO, answers nothing, and reads until
/// the client closes the connection.
fn silent(peer: *Peer, io: Io) !void {
    try peer.accept(io);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    _ = (try peer.readCommand(arena.allocator())) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 0), try peer.readToEnd());
}

fn neverAnswers(io: Io) !void {
    var buffer: [128]u8 = undefined;
    {
        var peer: Peer = try .listen(io);
        defer peer.close(io);
        var server = try io.concurrent(silent, .{ &peer, io });
        defer server.cancel(io) catch {};
        var client: Client = try .init(testing.allocator, io, .{ .url = peer.url() });
        defer client.deinit();
        var d: Diagnostics = .{};
        const ctx = within(io, .fromMilliseconds(100));
        try testing.expectError(error.DeadlineExceeded, client.connect(io, ctx, &d));
        try testing.expect(ctx.isExpired(time.now(io)));
        try testing.expectEqualStrings(try std.fmt.bufPrint(&buffer, "the deadline passed while the client connected to 127.0.0.1:{d}", .{portOf(&peer)}), d.message());
        try server.await(io);
    }
    var peer: Peer = try .listen(io);
    defer peer.close(io);
    var server = try io.concurrent(silent, .{ &peer, io });
    defer server.cancel(io) catch {};
    var client: Client = try .init(testing.allocator, io, .{ .url = peer.url(), .connect_timeout = .fromMilliseconds(100) });
    defer client.deinit();
    var d: Diagnostics = .{};
    try testing.expectError(error.Unavailable, client.connect(io, .root, &d));
    try testing.expectEqualStrings(try std.fmt.bufPrint(&buffer, "127.0.0.1:{d} did not answer within connect_timeout (100 ms)", .{portOf(&peer)}), d.message());
    try testing.expectEqual(@as(?Diagnostics.Phase, .connect), d.phase);
    try server.await(io);
}

test "a context that has run out or a token canceled before connect opens nothing" {
    try within5s(testing.io, refusedContexts, .{testing.io});
}

fn refusedContexts(io: Io) !void {
    var peer: Peer = try .listen(io);
    defer peer.close(io);
    var client: Client = try .init(testing.allocator, io, .{ .url = peer.url() });
    defer client.deinit();
    var d: Diagnostics = .{};
    const expired = core.Context.root.withDeadline(.at(time.now(io)));
    try testing.expectError(error.DeadlineExceeded, client.connect(io, expired, &d));
    try testing.expectEqualStrings("less than 1 ms was left of the deadline before the client connected", d.message());
    var token: core.CancellationToken = .init;
    token.cancel();
    try testing.expectError(error.Cancelled, client.connect(io, core.Context.root.withCancellation(&token), &d));
    try testing.expectEqualStrings("the token was canceled before the client connected", d.message());
    try testing.expect(!try connectsWithin(io, &peer, .fromMilliseconds(50)));
}

test "close stops a connect in progress, close twice is fine, and connect after close is Closed, also where a shutdown does not end a read and where the client starts slowly" {
    var windows: WindowsLike = undefined;
    var slow: SlowConnect = undefined;
    for ([_]Io{ testing.io, windows.io(), slow.io() }) |io| try within5s(testing.io, closeWhileConnecting, .{io});
}

fn connectStopped(client: *Client, io: Io, d: *Diagnostics) !void {
    try testing.expectError(error.Closed, client.connect(io, .root, d));
}

/// `silent`, which sets `heard` once it has HELLO.
fn hearHello(peer: *Peer, io: Io, heard: *Io.Event) !void {
    try peer.accept(io);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    _ = (try peer.readCommand(arena.allocator())) orelse return error.TestUnexpectedResult;
    heard.set(io);
    try testing.expectEqual(@as(usize, 0), try peer.readToEnd());
}

/// The client on `io`, the server's side on `std.testing.io`.
fn closeWhileConnecting(io: Io) !void {
    var peer: Peer = try .listen(testing.io);
    defer peer.close(testing.io);
    var heard: Io.Event = .unset;
    var server = try testing.io.concurrent(hearHello, .{ &peer, testing.io, &heard });
    defer server.cancel(testing.io) catch {};
    var client: Client = try .init(testing.allocator, io, .{ .url = peer.url() });
    defer client.deinit();
    var d: Diagnostics = .{};
    var connecting = try io.concurrent(connectStopped, .{ &client, io, &d });
    defer connecting.cancel(io) catch {};
    // Once the server has HELLO, the client waits for the reply, or soon
    // will: close stops it either way. A sleep in place of this wait loses
    // to a client that starts slowly, which close stops before HELLO.
    try heard.wait(testing.io);
    const start = time.now(io);
    client.close(io);
    try connecting.await(io);
    try testing.expect(start.durationTo(time.now(io)).toMilliseconds() < 1000);
    try testing.expectEqualStrings("the client was closed while it connected", d.message());
    try server.await(testing.io);
    client.close(io);
    try testing.expectError(error.Closed, client.connect(io, .root, &d));
    try testing.expectEqualStrings("the client is closed", d.message());
}

/// `std.testing.io` whose connections come 100 ms late, as on a busy
/// machine: the socket connects at once and is handed over after the
/// wait; a cancelation of the wait closes it.
const SlowConnect = struct {
    vtable: Io.VTable,

    fn io(s: *SlowConnect) Io {
        s.vtable = testing.io.vtable.*;
        s.vtable.netConnectIp = connectLate;
        return .{ .userdata = testing.io.userdata, .vtable = &s.vtable };
    }

    fn connectLate(userdata: ?*anyopaque, address: *const net.IpAddress, options: net.IpAddress.ConnectOptions) net.IpAddress.ConnectError!net.Socket {
        const socket = try testing.io.vtable.netConnectIp(userdata, address, options);
        testing.io.sleep(.fromMilliseconds(100), .awake) catch |err| {
            testing.io.vtable.netClose(userdata, &.{socket});
            return err;
        };
        return socket;
    }
};

test "deinit without close closes the connection" {
    try within5s(testing.io, deinitCloses, .{testing.io});
}

fn deinitCloses(io: Io) !void {
    var peer: Peer = try .listen(io);
    defer peer.close(io);
    var client: Client = try .init(testing.allocator, io, .{ .url = peer.url() });
    var server = try io.concurrent(shakeHands, .{ &peer, io });
    defer server.cancel(io) catch {};
    client.connect(io, .root, null) catch |err| {
        client.deinit();
        return err;
    };
    try server.await(io);
    client.deinit();
    try testing.expectEqual(@as(usize, 0), try peer.readToEnd());
}
