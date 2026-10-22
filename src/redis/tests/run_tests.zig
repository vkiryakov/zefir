//! Tests of `redis.Client.run` by the rules of its calls, against
//! `redis.testing.FakeServer` and `FakeServer.Peer` over loopback, with
//! commands of `cmd.raw`: the deadline and the token before anything goes
//! out, the deadline and the task while the command is out, the memory of
//! the reply, the pushes and attributes a server sends, and what each
//! error leaves of the connection and the pool. No call is ever made
//! twice. Every test runs under a time limit of 5 s.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const core = @import("core");
const redis = @import("../root.zig");
const cmd = redis.cmd;
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

/// `GET k`, read into a number: its reply needs no memory.
const get = cmd.raw(?i64, .{ "GET", "k" });

/// A client of `options`, connected.
fn connected(io: Io, client: *Client, options: Client.Options) !void {
    client.* = try .init(testing.allocator, io, options);
    errdefer client.deinit();
    var d: Diagnostics = .{};
    client.connect(io, .root, &d) catch |err| {
        std.debug.print("connect: {t}: {s}\n", .{ err, d.message() });
        return err;
    };
}

/// Waits until the server has `count` commands in its journal.
fn awaitReceived(io: Io, server: *FakeServer, count: usize) !void {
    const give_up: core.Deadline = .after(time.now(io), .fromSeconds(4));
    while (server.received(io) != count) {
        if (time.expired(io, give_up)) return error.TestTimedOut;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}

fn awaitWaiting(io: Io, client: *Client, count: usize) !void {
    const give_up: core.Deadline = .after(time.now(io), .fromSeconds(4));
    while (client.pool.counts(io).waiting != count) {
        if (time.expired(io, give_up)) return error.TestTimedOut;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}

/// The connection of the journal's command number `i`.
fn connectionOf(io: Io, server: *FakeServer, i: usize) !u32 {
    return (try server.entry(io, i)).connection;
}

fn quiet() std.log.Level {
    const level = testing.log_level;
    testing.log_level = .err;
    return level;
}

test "before connect a call is Unavailable, and nothing goes out" {
    try within5s(testing.io, beforeConnect, .{testing.io});
}

fn beforeConnect(io: Io) !void {
    var server: FakeServer = try .start(testing.allocator, io, &.{});
    defer server.stop(io);
    var client: Client = try .init(testing.allocator, io, .{ .url = server.url() });
    defer client.deinit();
    var d: Diagnostics = .{};
    try testing.expectError(error.Unavailable, client.run(io, .of(.root), get, .{ .diagnostics = &d }));
    try testing.expectEqualStrings("connect() has not succeeded", d.message());
    try testing.expectEqual(Diagnostics.Phase.checkout, d.phase.?);
    try testing.expectEqual(@as(usize, 0), server.received(io));
}

test "a call answers with the reply of its command, and a Diagnostics used again holds nothing of the error before" {
    try within5s(testing.io, diagnosticsAfresh, .{testing.io});
}

fn diagnosticsAfresh(io: Io) !void {
    var server: FakeServer = try .start(testing.allocator, io, &.{
        .expect(.{ "GET", "k" }, .{ .err = "WRONGTYPE Operation against a key holding the wrong kind of value" }),
        .expect(.{ "GET", "k" }, .{ .string = "42" }),
    });
    defer server.stop(io);
    var client: Client = undefined;
    try connected(io, &client, .{ .url = server.url() });
    defer client.deinit();
    var d: Diagnostics = .{};
    try testing.expectError(error.ServerError, client.run(io, .of(.root), get, .{ .diagnostics = &d }));
    try testing.expect(d.isCode("WRONGTYPE"));
    try testing.expectEqual(@as(?i64, 42), try client.run(io, .of(.root), get, .{ .diagnostics = &d }));
    try testing.expectEqualStrings("", d.message());
    try testing.expectEqualStrings("", d.code());
    try testing.expectEqual(@as(?Diagnostics.Phase, null), d.phase);
    try testing.expectEqual(@as(?anyerror, null), d.cause);
    try server.finish(io);
}

test "a deadline that has passed, or a canceled token, stops the call before it goes out" {
    try within5s(testing.io, beforeSending, .{testing.io});
}

fn beforeSending(io: Io) !void {
    var server: FakeServer = try .start(testing.allocator, io, &.{});
    defer server.stop(io);
    var client: Client = undefined;
    try connected(io, &client, .{ .url = server.url() });
    defer client.deinit();
    var d: Diagnostics = .{};
    const expired: redis.OperationContext = .of(core.Context.root.withDeadline(.at(time.now(io))));
    try testing.expectError(error.DeadlineExceeded, client.run(io, expired, get, .{ .diagnostics = &d }));
    try testing.expectEqualStrings("less than 1 ms was left of the deadline before the call", d.message());
    var token: core.CancellationToken = .init;
    token.cancel();
    try testing.expectError(error.Cancelled, client.run(io, .of(core.Context.root.withCancellation(&token)), get, .{ .diagnostics = &d }));
    try testing.expectEqualStrings("the token was canceled before the call", d.message());
    try testing.expectEqual(@as(usize, 0), server.received(io));
    // The connection stayed in the pool.
    try testing.expectEqual(@as(usize, 1), client.pool.counts(io).idle);
}

test "a reply that holds strings without .allocator is InvalidArgument, and nothing goes out" {
    try within5s(testing.io, needsAllocator, .{testing.io});
}

fn needsAllocator(io: Io) !void {
    var server: FakeServer = try .start(testing.allocator, io, &.{});
    defer server.stop(io);
    var client: Client = undefined;
    try connected(io, &client, .{ .url = server.url() });
    defer client.deinit();
    var d: Diagnostics = .{};
    try testing.expectError(error.InvalidArgument, client.run(io, .of(.root), cmd.raw([]const u8, .{ "GET", "k" }), .{ .diagnostics = &d }));
    try testing.expectEqualStrings("the reply of GET holds strings: pass .allocator", d.message());
    const parts: []const []const u8 = &.{ "LRANGE", "k", "0", "-1" };
    try testing.expectError(error.InvalidArgument, client.run(io, .of(.root), cmd.raw([]const i64, parts), .{ .diagnostics = &d }));
    try testing.expectEqualStrings("the reply of LRANGE holds slices: pass .allocator", d.message());
    // A rule of the command itself comes first.
    try testing.expectError(error.InvalidArgument, client.run(io, .of(.root), cmd.raw([]const u8, .{}), .{ .diagnostics = &d }));
    try testing.expectEqualStrings("redis.cmd.raw: no arguments: the first is the name of the command", d.message());
    try testing.expectEqual(@as(usize, 0), server.received(io));
}

test "the reply comes from .allocator, and a call on a warm pool takes nothing of the client's own memory" {
    try within5s(testing.io, replyMemory, .{testing.io});
}

fn replyMemory(io: Io) !void {
    var server: FakeServer = try .start(testing.allocator, io, &.{
        .expect(.{ "GET", "k" }, .{ .string = "a value of the reply" }),
    });
    defer server.stop(io);
    var counting: testing.FailingAllocator = .init(testing.allocator, .{});
    var client: Client = try .init(counting.allocator(), io, .{ .url = server.url() });
    defer client.deinit();
    try client.connect(io, .root, null);
    var reply_memory: testing.FailingAllocator = .init(testing.allocator, .{});
    var arena: std.heap.ArenaAllocator = .init(reply_memory.allocator());
    const live = counting.allocations - counting.deallocations;
    const value = try client.run(io, .of(.root), cmd.raw([]const u8, .{ "GET", "k" }), .{ .allocator = arena.allocator() });
    try testing.expectEqualStrings("a value of the reply", value);
    try testing.expectEqual(live, counting.allocations - counting.deallocations);
    try testing.expect(reply_memory.allocated_bytes > 0);
    arena.deinit();
    try testing.expectEqual(reply_memory.allocated_bytes, reply_memory.freed_bytes);
    try server.finish(io);
}

test "a reply later than the deadline is Timeout and closes its connection, and the next call goes on a new one" {
    try within5s(testing.io, lateReply, .{testing.io});
}

const late: FakeServer.Reply = .{ .string = "7" };
const after200: FakeServer.Reply = .{ .delayed = .{ .after = .fromMilliseconds(200), .reply = &late } };

fn lateReply(io: Io) !void {
    var server: FakeServer = try .start(testing.allocator, io, &.{
        .expect(.{ "GET", "k" }, after200),
        .expect(.{ "GET", "k" }, .{ .string = "8" }),
    });
    defer server.stop(io);
    var client: Client = undefined;
    try connected(io, &client, .{ .url = server.url() });
    defer client.deinit();
    var d: Diagnostics = .{};
    const ctx = within(io, .fromMilliseconds(50));
    try testing.expectError(error.Timeout, client.run(io, ctx, get, .{ .diagnostics = &d }));
    try testing.expect(ctx.ctx.isExpired(time.now(io)));
    try testing.expectEqualStrings("the deadline passed before the reply came", d.message());
    try testing.expectEqual(Diagnostics.Phase.wait, d.phase.?);
    try testing.expectEqual(@as(usize, 0), client.pool.counts(io).idle + client.pool.counts(io).in_use);
    try testing.expectEqual(@as(?i64, 8), try client.run(io, .of(.root), get, .{}));
    try testing.expectEqual(@as(u32, 1), try connectionOf(io, &server, 0));
    try testing.expectEqual(@as(u32, 2), try connectionOf(io, &server, 1));
    // A timeout closes its own connection only.
    try testing.expectEqual(@as(u64, 0), client.pool.counts(io).clears);
    try server.finish(io);
}

test "Options.timeout bounds a call whose context has no deadline, and with null the call waits for its reply" {
    try within5s(testing.io, defaultTimeout, .{testing.io});
}

fn defaultTimeout(io: Io) !void {
    var server: FakeServer = try .start(testing.allocator, io, &.{
        .expect(.{ "GET", "k" }, after200),
        .expect(.{ "GET", "k" }, after200),
    });
    defer server.stop(io);
    {
        var client: Client = undefined;
        try connected(io, &client, .{ .url = server.url(), .timeout = .fromMilliseconds(50) });
        defer client.deinit();
        const start = time.now(io);
        try testing.expectError(error.Timeout, client.run(io, .of(.root), get, .{}));
        const took = start.durationTo(time.now(io)).toMilliseconds();
        try testing.expect(took >= 50 and took < 200);
    }
    var client: Client = undefined;
    try connected(io, &client, .{ .url = server.url(), .timeout = null });
    defer client.deinit();
    const start = time.now(io);
    try testing.expectEqual(@as(?i64, 7), try client.run(io, .of(.root), get, .{}));
    try testing.expect(start.durationTo(time.now(io)).toMilliseconds() >= 200);
    try server.finish(io);
}

test "less of the deadline left than the shortest round trip to the server is DeadlineExceeded, and nothing goes out" {
    try within5s(testing.io, shortestRoundTrip, .{testing.io});
}

/// The server's side: two connections whose HELLO it answers after 20 ms.
/// The first gets a command that it never answers; the second the command
/// of the call that opened it, which it answers, and then nothing.
fn slowHellos(peer: *Peer, io: Io) !void {
    try peer.accept(io);
    try peers.shakeHands(peer, io, .fromMilliseconds(20));
    try peers.expectCommand(peer, &.{ "GET", "k" });
    // Until the client gives up on it and closes it; then it opens the
    // second.
    try testing.expectEqual(@as(usize, 0), try peer.readToEnd());
    try peer.accept(io);
    try peers.shakeHands(peer, io, .fromMilliseconds(20));
    try peers.expectCommand(peer, &.{ "GET", "k" });
    try peer.send(":5\r\n");
    try testing.expectEqual(@as(usize, 0), try peer.readToEnd());
}

fn shortestRoundTrip(io: Io) !void {
    var peer: Peer = try .listen(io);
    defer peer.close(io);
    var server = try io.concurrent(slowHellos, .{ &peer, io });
    defer server.cancel(io) catch {};
    {
        var client: Client = try .init(testing.allocator, io, .{ .url = peer.url() });
        defer client.deinit();
        try client.connect(io, .root, null);
        // One round trip says too little: the call goes out.
        try testing.expectError(error.Timeout, client.run(io, within(io, .fromMilliseconds(100)), get, .{}));
        try testing.expectEqual(@as(?i64, 5), try client.run(io, within(io, .fromSeconds(4)), get, .{}));
        try testing.expect(client.round_trips.min(io).toMilliseconds() >= 20);
        var d: Diagnostics = .{};
        try testing.expectError(error.DeadlineExceeded, client.run(io, within(io, .fromMilliseconds(10)), get, .{ .diagnostics = &d }));
        try testing.expect(std.mem.startsWith(u8, d.message(), "less of the deadline was left than the shortest round trip to the server ("));
        try testing.expectEqual(Diagnostics.Phase.send, d.phase.?);
    }
    try server.await(io);
}

test "a token canceled while the call waits in line is Cancelled once the call has its connection; nothing goes out, and the connection goes back" {
    try within5s(testing.io, canceledInLine, .{testing.io});
}

fn holdTheConnection(io: Io, client: *Client) !void {
    try testing.expectEqual(@as(?i64, 7), try client.run(io, .of(.root), get, .{}));
}

fn waitWithToken(io: Io, client: *Client, token: *const core.CancellationToken) !void {
    var d: Diagnostics = .{};
    try testing.expectError(error.Cancelled, client.run(io, .of(core.Context.root.withCancellation(token)), get, .{ .diagnostics = &d }));
    try testing.expectEqualStrings("the token was canceled before the command went out", d.message());
    try testing.expectEqual(Diagnostics.Phase.send, d.phase.?);
}

fn canceledInLine(io: Io) !void {
    var server: FakeServer = try .start(testing.allocator, io, &.{.expect(.{ "GET", "k" }, after200)});
    defer server.stop(io);
    var client: Client = undefined;
    try connected(io, &client, .{ .url = server.url(), .max_connections = 1 });
    defer client.deinit();
    var holder = try io.concurrent(holdTheConnection, .{ io, &client });
    defer holder.cancel(io) catch {};
    try awaitReceived(io, &server, 1);
    var token: core.CancellationToken = .init;
    var waiter = try io.concurrent(waitWithToken, .{ io, &client, &token });
    defer waiter.cancel(io) catch {};
    try awaitWaiting(io, &client, 1);
    // The token is no alarm: the call goes on waiting for its turn.
    token.cancel();
    try holder.await(io);
    try waiter.await(io);
    try testing.expectEqual(@as(usize, 1), server.received(io));
    try testing.expectEqual(@as(usize, 1), client.pool.counts(io).idle);
    try server.finish(io);
}

test "the task canceled while the command is out is Interrupted, and the task stays canceled" {
    try within5s(testing.io, interrupted, .{testing.io});
}

const after1s: FakeServer.Reply = .{ .delayed = .{ .after = .fromSeconds(1), .reply = &late } };

fn holdAndBeCanceled(io: Io, client: *Client) !void {
    var d: Diagnostics = .{};
    try testing.expectError(error.Interrupted, client.run(io, .of(.root), get, .{ .diagnostics = &d }));
    try testing.expectEqualStrings("the task was canceled while the command was out", d.message());
    try testing.expectError(error.Canceled, io.checkCancel());
}

fn interrupted(io: Io) !void {
    var server: FakeServer = try .start(testing.allocator, io, &.{.expect(.{ "GET", "k" }, after1s)});
    defer server.stop(io);
    var client: Client = undefined;
    try connected(io, &client, .{ .url = server.url() });
    defer client.deinit();
    var call = try io.concurrent(holdAndBeCanceled, .{ io, &client });
    defer call.cancel(io) catch {};
    try awaitReceived(io, &server, 1);
    try call.cancel(io);
    // The cancelation closed the connection.
    const counts = client.pool.counts(io);
    try testing.expectEqual(@as(usize, 0), counts.idle + counts.in_use);
    try testing.expectEqual(@as(u64, 0), counts.clears);
}

test "a token canceled while the command is out leaves the reply as it came" {
    try within5s(testing.io, tokenInFlight, .{testing.io});
}

fn callWithToken(io: Io, client: *Client, token: *const core.CancellationToken) !?i64 {
    return client.run(io, .of(core.Context.root.withCancellation(token)), get, .{});
}

fn tokenInFlight(io: Io) !void {
    var server: FakeServer = try .start(testing.allocator, io, &.{.expect(.{ "GET", "k" }, after200)});
    defer server.stop(io);
    var client: Client = undefined;
    try connected(io, &client, .{ .url = server.url() });
    defer client.deinit();
    var token: core.CancellationToken = .init;
    var call = try io.concurrent(callWithToken, .{ io, &client, &token });
    defer _ = call.cancel(io) catch null;
    try awaitReceived(io, &server, 1);
    token.cancel();
    try testing.expectEqual(@as(?i64, 7), try call.await(io));
    try testing.expectEqual(@as(usize, 1), client.pool.counts(io).idle);
    try server.finish(io);
}

test "a push before a reply and an attribute inside it are skipped, and the next call reads its own reply" {
    try within5s(testing.io, pushesSkipped, .{testing.io});
}

fn pushesSkipped(io: Io) !void {
    var server: FakeServer = try .start(testing.allocator, io, &.{
        .expect(.{ "LRANGE", "k", "0", "-1" }, .{ .raw = ">2\r\n$10\r\ninvalidate\r\n_\r\n*2\r\n:1\r\n|1\r\n+ttl\r\n:3600\r\n:2\r\n" }),
        .expect(.{ "GET", "k" }, .{ .string = "3" }),
    });
    defer server.stop(io);
    var client: Client = undefined;
    try connected(io, &client, .{ .url = server.url() });
    defer client.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const list = try client.run(io, .of(.root), cmd.raw([]const i64, .{ "LRANGE", "k", "0", "-1" }), .{ .allocator = arena.allocator() });
    try testing.expectEqualSlices(i64, &.{ 1, 2 }, list);
    try testing.expectEqual(@as(?i64, 3), try client.run(io, .of(.root), get, .{}));
    try testing.expectEqual(@as(u32, 1), try connectionOf(io, &server, 1));
    try server.finish(io);
}

test "UnexpectedReply and ServerError leave the connection as it was: the next call goes on the same one" {
    try within5s(testing.io, errorsKeepConnection, .{testing.io});
}

fn errorsKeepConnection(io: Io) !void {
    var server: FakeServer = try .start(testing.allocator, io, &.{
        .expect(.{ "GET", "k" }, .{ .string = "abc" }),
        .expect(.{ "GET", "k" }, .{ .err = "WRONGTYPE Operation against a key holding the wrong kind of value" }),
        .expect(.{ "GET", "k" }, .{ .integer = 9 }),
    });
    defer server.stop(io);
    var client: Client = undefined;
    try connected(io, &client, .{ .url = server.url() });
    defer client.deinit();
    var d: Diagnostics = .{};
    try testing.expectError(error.UnexpectedReply, client.run(io, .of(.root), get, .{ .diagnostics = &d }));
    try testing.expectEqualStrings("the reply is a bulk string of 3 bytes, and the call asked for ?i64", d.message());
    try testing.expectError(error.ServerError, client.run(io, .of(.root), get, .{ .diagnostics = &d }));
    try testing.expect(d.isCode("WRONGTYPE"));
    try testing.expectEqual(@as(?i64, 9), try client.run(io, .of(.root), get, .{}));
    for (0..3) |i| try testing.expectEqual(@as(u32, 1), try connectionOf(io, &server, i));
    try server.finish(io);
}

test "a reply that breaks RESP3 is ProtocolViolation and closes its connection, and the next call goes on a new one" {
    try within5s(testing.io, brokenReply, .{testing.io});
}

fn brokenReply(io: Io) !void {
    var server: FakeServer = try .start(testing.allocator, io, &.{
        .expect(.{ "GET", "k" }, .{ .malformed = .unknown_type }),
        .expect(.{ "GET", "k" }, .{ .integer = 1 }),
    });
    defer server.stop(io);
    var client: Client = undefined;
    try connected(io, &client, .{ .url = server.url() });
    defer client.deinit();
    try testing.expectError(error.ProtocolViolation, client.run(io, .of(.root), get, .{}));
    try testing.expectEqual(@as(?i64, 1), try client.run(io, .of(.root), get, .{}));
    try testing.expectEqual(@as(u32, 2), try connectionOf(io, &server, 1));
    try testing.expectEqual(@as(u64, 0), client.pool.counts(io).clears);
    try server.finish(io);
}

test "a connection that the server closes is ConnectionLost and clears the pool; the command went out once, and the next call opens anew, also where the end of the stream reads as error.Unexpected" {
    var windows: WindowsLike = undefined;
    try within5s(testing.io, connectionLost, .{ testing.io, " closed the connection" });
    try within5s(testing.io, connectionLost, .{ windows.io(), " broke: Unexpected" });
}

/// The client on `io`, the server on `std.testing.io`.
fn connectionLost(io: Io, ending: []const u8) !void {
    const level = quiet();
    defer testing.log_level = level;
    var server: FakeServer = try .start(testing.allocator, testing.io, &.{
        .expect(.{ "GET", "k" }, .close_connection),
        .expect(.{ "GET", "k" }, .{ .integer = 2 }),
    });
    defer server.stop(testing.io);
    var client: Client = undefined;
    try connected(io, &client, .{ .url = server.url() });
    defer client.deinit();
    var d: Diagnostics = .{};
    try testing.expectError(error.ConnectionLost, client.run(io, .of(.root), get, .{ .diagnostics = &d }));
    try testing.expect(std.mem.endsWith(u8, d.message(), ending));
    const counts = client.pool.counts(io);
    try testing.expectEqual(@as(u64, 1), counts.clears);
    try testing.expectEqual(@as(u64, 1), counts.generation);
    // No retry: the command came once.
    try testing.expectEqual(@as(usize, 1), server.count(testing.io, "GET"));
    // The pool is paused: this call is its probe.
    try testing.expectEqual(@as(?i64, 2), try client.run(io, .of(.root), get, .{}));
    try testing.expectEqual(@as(u32, 2), try connectionOf(testing.io, &server, 1));
    try server.finish(testing.io);
}

test "a server that refuses the user of a new connection is AuthenticationFailed, and clears the pool" {
    try within5s(testing.io, refusedUser, .{testing.io});
}

/// The server's side: a first connection whose command it never answers,
/// then a second whose HELLO it refuses.
fn refuseSecond(peer: *Peer, io: Io) !void {
    try peer.accept(io);
    try peers.shakeHands(peer, io, .zero);
    try peers.expectCommand(peer, &.{ "GET", "k" });
    try testing.expectEqual(@as(usize, 0), try peer.readToEnd());
    try peer.accept(io);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    _ = (try peer.readCommand(arena.allocator())) orelse return error.TestUnexpectedResult;
    try peer.send("-WRONGPASS invalid username-password pair or user is disabled.\r\n");
    try testing.expectEqual(@as(usize, 0), try peer.readToEnd());
}

fn refusedUser(io: Io) !void {
    const level = quiet();
    defer testing.log_level = level;
    var peer: Peer = try .listen(io);
    defer peer.close(io);
    var server = try io.concurrent(refuseSecond, .{ &peer, io });
    defer server.cancel(io) catch {};
    {
        var client: Client = try .init(testing.allocator, io, .{ .url = peer.url() });
        defer client.deinit();
        try client.connect(io, .root, null);
        try testing.expectError(error.Timeout, client.run(io, within(io, .fromMilliseconds(100)), get, .{}));
        var d: Diagnostics = .{};
        try testing.expectError(error.AuthenticationFailed, client.run(io, .of(.root), get, .{ .diagnostics = &d }));
        try testing.expect(d.isCode("WRONGPASS"));
        const counts = client.pool.counts(io);
        try testing.expectEqual(@as(u64, 1), counts.clears);
        try testing.expectEqual(@as(u64, 1), counts.generation);
    }
    try server.await(io);
}

test "a command that changes the state of its connection is InvalidArgument in raw, in any case, and nothing goes out, alone, in a pipeline or in a transaction" {
    try within5s(testing.io, bannedCommands, .{testing.io});
}

/// A banned command and what its refusal says to use instead; empty where
/// nothing replaces it.
const Ban = struct { []const []const u8, []const u8 };

const bans = [_]Ban{
    .{ &.{ "HELLO", "3" }, "the handshake of the client" },
    .{ &.{ "AUTH", "app", "pass" }, "the handshake of the client" },
    .{ &.{"RESET"}, "the handshake of the client" },
    .{ &.{ "SELECT", "3" }, "the database in the path of the URL" },
    .{ &.{ "select", "3" }, "the database in the path of the URL" },
    .{ &.{"QUIT"}, "client.close" },
    .{ &.{"MULTI"}, "conn.transaction" },
    .{ &.{"EXEC"}, "conn.transaction" },
    .{ &.{"DISCARD"}, "conn.transaction" },
    .{ &.{ "WATCH", "k" }, "redis.cmd.watch" },
    .{ &.{"UNWATCH"}, "redis.cmd.unwatch" },
    .{ &.{ "SUBSCRIBE", "orders" }, "client.subscribe" },
    .{ &.{ "PSUBSCRIBE", "orders:*" }, "client.subscribe" },
    .{ &.{ "SSUBSCRIBE", "orders" }, "client.subscribe" },
    .{ &.{"UNSUBSCRIBE"}, "client.subscribe" },
    .{ &.{"PUNSUBSCRIBE"}, "client.subscribe" },
    .{ &.{"SUNSUBSCRIBE"}, "client.subscribe" },
    .{ &.{"MONITOR"}, "" },
    .{ &.{"SYNC"}, "" },
    .{ &.{ "PSYNC", "?", "-1" }, "" },
    .{ &.{ "REPLCONF", "listening-port", "6380" }, "" },
    .{ &.{ "CLIENT", "REPLY", "OFF" }, "" },
    .{ &.{ "Client", "Reply", "SKIP" }, "" },
    .{ &.{ "CLIENT", "TRACKING", "ON" }, "" },
    .{ &.{ "CLIENT", "CACHING", "YES" }, "" },
    .{ &.{"READONLY"}, "" },
    .{ &.{"READWRITE"}, "" },
    .{ &.{"ASKING"}, "" },
};

fn bannedCommands(io: Io) !void {
    var server: FakeServer = try .start(testing.allocator, io, &.{
        .expect(.{ "CLIENT", "INFO" }, .{ .string = "id=3 addr=127.0.0.1:50000 lib-name=zefir-redis" }),
    });
    defer server.stop(io);
    var client: Client = undefined;
    try connected(io, &client, .{ .url = server.url() });
    defer client.deinit();
    var d: Diagnostics = .{};
    for (bans) |ban| {
        const parts, const instead = ban;
        const command = cmd.raw(void, parts);
        try testing.expectError(error.InvalidArgument, client.run(io, .of(.root), command, .{ .diagnostics = &d }));
        try testing.expect(std.mem.startsWith(u8, d.message(), "redis.cmd.raw: "));
        try testing.expect(std.mem.indexOf(u8, d.message(), instead) != null);
    }
    try testing.expectEqualStrings("redis.cmd.raw: SELECT would send the later calls on the connection to another database: put the database in the path of the URL", blk: {
        _ = client.run(io, .of(.root), cmd.raw(void, .{ "select", 3 }), .{ .diagnostics = &d }) catch {};
        break :blk d.message();
    });
    try testing.expectEqualStrings("redis.cmd.raw: CLIENT REPLY breaks the count of replies; the client does not run it", blk: {
        _ = client.run(io, .of(.root), cmd.raw(void, .{ .client, .reply, .off }), .{ .diagnostics = &d }) catch {};
        break :blk d.message();
    });
    // A whole pipeline and a whole transaction stop at a banned command.
    try testing.expectError(error.InvalidArgument, client.pipeline(io, .of(.root), .{ get, cmd.raw(void, .{"MULTI"}) }, .{ .diagnostics = &d }));
    try testing.expectEqual(@as(?usize, 1), d.command);
    var conn = try client.acquire(io, .of(.root));
    defer conn.release(io);
    try testing.expectError(error.InvalidArgument, conn.transaction(io, .of(.root), .{ get, cmd.raw(void, .{ "SELECT", "1" }) }, .{ .diagnostics = &d }));
    try testing.expectEqual(@as(?usize, 1), d.command);
    try testing.expectEqual(@as(usize, 0), server.received(io));
    // CLIENT with another subcommand goes.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const info = try conn.run(io, .of(.root), cmd.raw([]const u8, .{ "CLIENT", "INFO" }), .{ .allocator = arena.allocator() });
    try testing.expect(std.mem.indexOf(u8, info, "lib-name=zefir-redis") != null);
    try server.finish(io);
}
