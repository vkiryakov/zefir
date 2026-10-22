//! Tests of the check of an idle connection: one that lay in the pool for
//! longer than the threshold gets PING, under the call's deadline, before
//! the call's command goes on it. Any reply means it is alive; the end of
//! the stream closes it, and the call takes another; no reply by the
//! deadline is DeadlineExceeded, and the command never goes out. The
//! threshold, 30 s, is shortened through the pool's internal field.
//! Against `redis.testing.FakeServer` and `FakeServer.Peer` over loopback;
//! every test runs under a time limit of 5 s. A connection that the server
//! closed is checked on the `Io` of `windows_like_io.zig` too, where the
//! end of a stream reads as `error.Unexpected` and a shutdown does not end
//! the read that waits on it.

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const testing = std.testing;
const core = @import("core");
const redis = @import("../root.zig");
const resp = @import("../resp.zig");
const cmd = redis.cmd;
const Client = redis.Client;
const Diagnostics = redis.Diagnostics;
const FakeServer = redis.testing.FakeServer;
const Peer = FakeServer.Peer;
const time = @import("../engine/time.zig");
const peers = @import("peers.zig");
const WindowsLike = @import("windows_like_io.zig").WindowsLike;
const within5s = @import("time_limit.zig").within5s;

const get = cmd.raw(?i64, .{ "GET", "k" });

const threshold: Io.Duration = .fromMilliseconds(50);
/// Longer than the threshold.
const idling: Io.Duration = .fromMilliseconds(60);

fn within(io: Io, duration: Io.Duration) redis.OperationContext {
    return .of(core.Context.root.withDeadline(.after(time.now(io), duration)));
}

/// A client of `url` with the threshold of the check shortened, connected.
fn connected(io: Io, client: *Client, url: []const u8) !void {
    client.* = try .init(testing.allocator, io, .{ .url = url });
    errdefer client.deinit();
    client.pool.options.idle_check = threshold;
    try client.connect(io, .root, null);
}

test "a connection that idled past the threshold gets PING, then the command, on the same connection; one that did not gets none" {
    try within5s(testing.io, pingFirst, .{testing.io});
}

fn pingFirst(io: Io) !void {
    var server: FakeServer = try .start(testing.allocator, io, &.{
        .expect(.{ "GET", "k" }, .{ .integer = 5 }),
        .expect(.{ "GET", "k" }, .{ .integer = 6 }),
    });
    defer server.stop(io);
    var client: Client = undefined;
    try connected(io, &client, server.url());
    defer client.deinit();
    try redis.testing.sleepAtLeast(io, idling);
    try testing.expectEqual(@as(?i64, 5), try client.run(io, .of(.root), get, .{}));
    const ping = try server.entry(io, 0);
    try testing.expectEqualStrings("PING", ping.args[0]);
    try testing.expectEqual(@as(usize, 1), ping.args.len);
    try testing.expectEqual(ping.connection, (try server.entry(io, 1)).connection);
    // A connection that idled for less goes out as it is.
    client.pool.options.idle_check = .fromSeconds(10);
    try testing.expectEqual(@as(?i64, 6), try client.run(io, .of(.root), get, .{}));
    try testing.expectEqual(@as(usize, 1), server.count(io, "PING"));
    try testing.expectEqual(@as(usize, 3), server.received(io));
    try server.finish(io);
}

test "a connection that the server closed while it idled fails its check: it closes, and the call goes on a new one without an error, also where the end of the stream reads as error.Unexpected" {
    var windows: WindowsLike = undefined;
    // The client and the server on each.
    for ([_]Io{ testing.io, windows.io() }) |io| try within5s(testing.io, closedWhileIdle, .{io});
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

fn closedWhileIdle(io: Io) !void {
    var server: FakeServer = try .start(testing.allocator, io, &.{
        .expect(.{"GO"}, .refuse_connections),
        .expect(.{ "GET", "k" }, .{ .integer = 5 }),
    });
    defer server.stop(io);
    var client: Client = undefined;
    try connected(io, &client, server.url());
    defer client.deinit();
    // The server goes away and comes back: the idle connection is gone.
    try goAway(io, &server);
    server.acceptConnections(io);
    try redis.testing.sleepAtLeast(io, idling);
    var d: Diagnostics = .{};
    try testing.expectEqual(@as(?i64, 5), try client.run(io, .of(.root), get, .{ .diagnostics = &d }));
    try testing.expectEqualStrings("", d.message());
    // The client's first connection is 1, that of GO 2.
    try testing.expectEqual(@as(u32, 3), (try server.entry(io, 1)).connection);
    const counts = client.pool.counts(io);
    try testing.expectEqual(@as(u64, 0), counts.clears);
    try testing.expectEqual(@as(usize, 1), counts.idle);
    try server.finish(io);
}

test "an error in reply to PING means the connection is alive: the command follows on it" {
    try within5s(testing.io, loadingIsAlive, .{testing.io});
}

/// The server's side: the handshake, then PING answered with LOADING,
/// then the command.
fn answerLoading(peer: *Peer, io: Io) !void {
    try peer.accept(io);
    try peers.shakeHands(peer, io, .zero);
    try peers.expectCommand(peer, &.{"PING"});
    try peer.send("-LOADING Redis is loading the dataset in memory\r\n");
    try peers.expectCommand(peer, &.{ "GET", "k" });
    try peer.send(":5\r\n");
    try testing.expectEqual(@as(usize, 0), try peer.readToEnd());
}

fn loadingIsAlive(io: Io) !void {
    var peer: Peer = try .listen(io);
    defer peer.close(io);
    var server = try io.concurrent(answerLoading, .{ &peer, io });
    defer server.cancel(io) catch {};
    {
        var client: Client = undefined;
        try connected(io, &client, peer.url());
        defer client.deinit();
        try redis.testing.sleepAtLeast(io, idling);
        var d: Diagnostics = .{};
        try testing.expectEqual(@as(?i64, 5), try client.run(io, .of(.root), get, .{ .diagnostics = &d }));
        try testing.expectEqualStrings("", d.message());
    }
    try server.await(io);
}

test "no reply to PING by the call's deadline is DeadlineExceeded: the connection closes, and the command never goes out" {
    try within5s(testing.io, silentPing, .{testing.io});
}

/// The server's side: the handshake, then PING, which it never answers.
fn swallowPing(peer: *Peer, io: Io) !void {
    try peer.accept(io);
    try peers.shakeHands(peer, io, .zero);
    try peers.expectCommand(peer, &.{"PING"});
    // Nothing after it: the client closes the connection.
    try testing.expectEqual(@as(usize, 0), try peer.readToEnd());
}

fn silentPing(io: Io) !void {
    var peer: Peer = try .listen(io);
    defer peer.close(io);
    var server = try io.concurrent(swallowPing, .{ &peer, io });
    defer server.cancel(io) catch {};
    {
        var client: Client = undefined;
        try connected(io, &client, peer.url());
        defer client.deinit();
        try redis.testing.sleepAtLeast(io, idling);
        var d: Diagnostics = .{};
        const ctx = within(io, .fromMilliseconds(100));
        try testing.expectError(error.DeadlineExceeded, client.run(io, ctx, get, .{ .diagnostics = &d }));
        try testing.expect(ctx.ctx.isExpired(time.now(io)));
        try testing.expectEqualStrings("the deadline passed while PING checked a connection that had idled", d.message());
        try testing.expectEqual(Diagnostics.Phase.checkout, d.phase.?);
        const counts = client.pool.counts(io);
        try testing.expectEqual(@as(usize, 0), counts.idle + counts.in_use);
        try testing.expectEqual(@as(u64, 0), counts.clears);
    }
    try server.await(io);
}
