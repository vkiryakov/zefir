//! Tests of `redis.Conn`, the connection of one task, against
//! `redis.testing.FakeServer` over loopback: `client.acquire` waits in line
//! as a call does, `release` gives the connection back or closes it when
//! keys may be under WATCH on it, an error that closes the connection
//! leaves the Conn empty, and `client.close` gives a Conn `close_timeout`
//! as a call of the client, between its calls too, then cuts it. Every
//! test runs under a time limit of 5 s.

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
const within5s = @import("time_limit.zig").within5s;

fn within(io: Io, duration: Io.Duration) redis.OperationContext {
    return .of(core.Context.root.withDeadline(.after(time.now(io), duration)));
}

fn connected(io: Io, client: *Client, options: Client.Options) !void {
    client.* = try .init(testing.allocator, io, options);
    errdefer client.deinit();
    try client.connect(io, .root, null);
}

fn connectionOf(io: Io, server: *FakeServer, i: usize) !u32 {
    return (try server.entry(io, i)).connection;
}

const get = cmd.raw(?i64, .{ "GET", "k" });

fn awaitReceived(io: Io, server: *FakeServer, count: usize) !void {
    const give_up: core.Deadline = .after(time.now(io), .fromSeconds(4));
    while (server.received(io) != count) {
        if (time.expired(io, give_up)) return error.TestTimedOut;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}

test "acquire takes a connection of the pool, which stats count in use, and another acquire waits in line until its deadline: PoolExhausted" {
    try within5s(testing.io, acquireWaits, .{testing.io});
}

fn acquireWaits(io: Io) !void {
    var server: FakeServer = try .start(testing.allocator, io, &.{});
    defer server.stop(io);
    var client: Client = undefined;
    try connected(io, &client, .{ .url = server.url(), .max_connections = 1 });
    defer client.deinit();
    var conn = try client.acquire(io, .of(.root));
    defer conn.release(io);
    try testing.expectEqual(@as(usize, 1), client.stats().in_use);
    try testing.expectEqual(@as(usize, 0), client.stats().idle);
    try testing.expectError(error.PoolExhausted, client.acquire(io, within(io, .fromMilliseconds(50))));
    try testing.expectError(error.PoolExhausted, client.run(io, within(io, .fromMilliseconds(50)), get, .{}));
    conn.release(io);
    try testing.expectEqual(@as(usize, 1), client.stats().idle);
}

test "release gives the connection back to the pool, and the next call goes on it" {
    try within5s(testing.io, releaseKeeps, .{testing.io});
}

fn releaseKeeps(io: Io) !void {
    var server: FakeServer = try .start(testing.allocator, io, &.{
        .expect(.{ "GET", "k" }, .{ .integer = 1 }),
        .expect(.{ "GET", "k" }, .{ .integer = 2 }),
    });
    defer server.stop(io);
    var client: Client = undefined;
    try connected(io, &client, .{ .url = server.url() });
    defer client.deinit();
    var conn = try client.acquire(io, .of(.root));
    try testing.expectEqual(@as(?i64, 1), try conn.run(io, .of(.root), get, .{}));
    conn.release(io);
    // A second release does nothing.
    conn.release(io);
    try testing.expectEqual(@as(?i64, 2), try client.run(io, .of(.root), get, .{}));
    try testing.expectEqual(try connectionOf(io, &server, 0), try connectionOf(io, &server, 1));
    try testing.expectEqual(@as(usize, 1), client.stats().connections);
    try server.finish(io);
}

test "release closes a connection that may hold keys under WATCH, and keeps one after UNWATCH" {
    try within5s(testing.io, releaseAfterWatch, .{testing.io});
}

fn releaseAfterWatch(io: Io) !void {
    var server: FakeServer = try .start(testing.allocator, io, &.{
        .expect(.{ "WATCH", "stock:coffee", "stock:tea" }, .ok),
        .expect(.{ "GET", "k" }, .{ .integer = 1 }),
        .expect(.{ "WATCH", "stock:coffee" }, .ok),
        .expect(.{"UNWATCH"}, .ok),
        .expect(.{ "GET", "k" }, .{ .integer = 2 }),
    });
    defer server.stop(io);
    var client: Client = undefined;
    try connected(io, &client, .{ .url = server.url() });
    defer client.deinit();
    {
        var conn = try client.acquire(io, .of(.root));
        defer conn.release(io);
        try conn.run(io, .of(.root), cmd.watch(&.{ "stock:coffee", "stock:tea" }), .{});
    }
    // The watching connection closed: the call opens another.
    try testing.expectEqual(@as(?i64, 1), try client.run(io, .of(.root), get, .{}));
    try testing.expectEqual(@as(u32, 1), try connectionOf(io, &server, 0));
    try testing.expectEqual(@as(u32, 2), try connectionOf(io, &server, 1));
    {
        var conn = try client.acquire(io, .of(.root));
        defer conn.release(io);
        try conn.run(io, .of(.root), cmd.watch(&.{"stock:coffee"}), .{});
        try conn.run(io, .of(.root), cmd.unwatch(), .{});
    }
    try testing.expectEqual(@as(?i64, 2), try client.run(io, .of(.root), get, .{}));
    for (2..5) |i| try testing.expectEqual(@as(u32, 2), try connectionOf(io, &server, i));
    try testing.expectEqual(@as(usize, 1), client.stats().connections);
    try server.finish(io);
}

test "WATCH of no keys is InvalidArgument, and nothing goes out" {
    try within5s(testing.io, watchNothing, .{testing.io});
}

fn watchNothing(io: Io) !void {
    var server: FakeServer = try .start(testing.allocator, io, &.{});
    defer server.stop(io);
    var client: Client = undefined;
    try connected(io, &client, .{ .url = server.url() });
    defer client.deinit();
    var conn = try client.acquire(io, .of(.root));
    defer conn.release(io);
    var d: Diagnostics = .{};
    try testing.expectError(error.InvalidArgument, conn.run(io, .of(.root), cmd.watch(&.{}), .{ .diagnostics = &d }));
    try testing.expectEqualStrings("redis.cmd.watch: no keys: WATCH takes one or more", d.message());
    try testing.expectEqual(@as(usize, 0), server.received(io));
}

test "a ServerError on a Conn keeps its connection; a connection that breaks leaves the Conn empty: Closed, and release only frees it" {
    try within5s(testing.io, errorsOnConn, .{testing.io});
}

fn errorsOnConn(io: Io) !void {
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;
    var server: FakeServer = try .start(testing.allocator, io, &.{
        .expect(.{ "GET", "k" }, .{ .err = "WRONGTYPE Operation against a key holding the wrong kind of value" }),
        .expect(.{ "GET", "k" }, .{ .integer = 4 }),
        .expect(.{ "GET", "k" }, .close_connection),
    });
    defer server.stop(io);
    var client: Client = undefined;
    try connected(io, &client, .{ .url = server.url() });
    defer client.deinit();
    var conn = try client.acquire(io, .of(.root));
    defer conn.release(io);
    var d: Diagnostics = .{};
    try testing.expectError(error.ServerError, conn.run(io, .of(.root), get, .{ .diagnostics = &d }));
    try testing.expect(d.isCode("WRONGTYPE"));
    try testing.expectEqual(@as(?i64, 4), try conn.run(io, .of(.root), get, .{}));
    try testing.expectError(error.ConnectionLost, conn.run(io, .of(.root), get, .{}));
    try testing.expectError(error.Closed, conn.run(io, .of(.root), get, .{ .diagnostics = &d }));
    try testing.expectEqualStrings("the Conn lost its connection to an error before: release it, and acquire another", d.message());
    try testing.expectError(error.Closed, conn.pipeline(io, .of(.root), .{get}, .{}));
    for (0..3) |i| try testing.expectEqual(@as(u32, 1), try connectionOf(io, &server, i));
    // The connection went back to the pool, which closed it.
    try testing.expectEqual(@as(usize, 0), client.stats().connections);
    conn.release(io);
    try testing.expectError(error.Closed, conn.run(io, .of(.root), get, .{ .diagnostics = &d }));
    try testing.expectEqualStrings("the Conn was released", d.message());
    try server.finish(io);
}

test "a pipeline on a Conn is one of the client on the connection of the Conn, and a WATCH in it counts for release" {
    try within5s(testing.io, pipelineOnConn, .{testing.io});
}

fn pipelineOnConn(io: Io) !void {
    var server: FakeServer = try .start(testing.allocator, io, &.{
        .expect(.{ "INCR", "a" }, .{ .integer = 1 }),
        .expect(.{ "INCR", "b" }, .{ .err = "WRONGTYPE Operation against a key holding the wrong kind of value" }),
        .expect(.{ "WATCH", "k" }, .ok),
        .expect(.{ "GET", "k" }, .{ .integer = 3 }),
        .expect(.{ "GET", "k" }, .{ .integer = 4 }),
    });
    defer server.stop(io);
    var client: Client = undefined;
    try connected(io, &client, .{ .url = server.url() });
    defer client.deinit();
    {
        var conn = try client.acquire(io, .of(.root));
        defer conn.release(io);
        var d: Diagnostics = .{};
        const r = try conn.pipeline(io, .of(.root), .{ cmd.raw(i64, .{ "INCR", "a" }), cmd.raw(i64, .{ "INCR", "b" }) }, .{ .diagnostics = &d });
        try testing.expectEqual(@as(i64, 1), try r[0]);
        try testing.expectError(error.ServerError, r[1]);
        try testing.expectEqual(@as(?usize, 1), d.command);
        const watched = try conn.pipeline(io, .of(.root), .{ cmd.watch(&.{"k"}), get }, .{});
        try watched[0];
        try testing.expectEqual(@as(?i64, 3), try watched[1]);
    }
    // The WATCH of the pipeline made release close the connection.
    try testing.expectEqual(@as(?i64, 4), try client.run(io, .of(.root), get, .{}));
    try testing.expectEqual(@as(u32, 1), try connectionOf(io, &server, 3));
    try testing.expectEqual(@as(u32, 2), try connectionOf(io, &server, 4));
    try server.finish(io);
}

test "close gives a call of a Conn close_timeout, then cuts it: ConnectionLost, and later calls are Closed" {
    try within5s(testing.io, closeCutsConn, .{testing.io});
}

const seven: FakeServer.Reply = .{ .integer = 7 };
const after1s: FakeServer.Reply = .{ .delayed = .{ .after = .fromSeconds(1), .reply = &seven } };

fn callOnConn(io: Io, conn: *redis.Conn) !void {
    var d: Diagnostics = .{};
    try testing.expectError(error.ConnectionLost, conn.run(io, .of(.root), get, .{ .diagnostics = &d }));
    try testing.expectEqualStrings("close() of the client cut the exchange", d.message());
}

fn closeCutsConn(io: Io) !void {
    var server: FakeServer = try .start(testing.allocator, io, &.{.expect(.{ "GET", "k" }, after1s)});
    defer server.stop(io);
    var client: Client = undefined;
    try connected(io, &client, .{ .url = server.url(), .close_timeout = .fromMilliseconds(100) });
    defer client.deinit();
    var conn = try client.acquire(io, .of(.root));
    defer conn.release(io);
    var out = try io.concurrent(callOnConn, .{ io, &conn });
    defer out.cancel(io) catch {};
    try awaitReceived(io, &server, 1);
    const start = time.now(io);
    client.close(io);
    const took = start.durationTo(time.now(io)).toMilliseconds();
    try out.await(io);
    try testing.expect(took >= 100 and took < 1000);
    var d: Diagnostics = .{};
    try testing.expectError(error.Closed, conn.run(io, .of(.root), get, .{ .diagnostics = &d }));
    try testing.expectError(error.Closed, client.acquire(io, .of(.root)));
    try testing.expectEqual(@as(usize, 0), client.stats().connections);
}

test "close gives a Conn held between calls close_timeout: the transaction after its WATCH runs meanwhile, and close returns once the Conn is released" {
    try within5s(testing.io, closeWaitsForConn, .{testing.io});
}

const queued: FakeServer.Reply = .{ .raw = "+QUEUED\r\n" };

/// The client's close, which sets `done` once it returns.
fn closeThenSet(client: *Client, io: Io, done: *Io.Event) void {
    client.close(io);
    done.set(io);
}

fn closeWaitsForConn(io: Io) !void {
    var server: FakeServer = try .start(testing.allocator, io, &.{
        .expect(.{ "WATCH", "stock" }, .ok),
        .expect(.{ "GET", "stock" }, .{ .integer = 5 }),
        .expect(.{"MULTI"}, .ok),
        .expect(.{ "DECR", "stock" }, queued),
        .expect(.{"EXEC"}, .{ .array = &.{.{ .integer = 4 }} }),
    });
    defer server.stop(io);
    var client: Client = undefined;
    try connected(io, &client, .{ .url = server.url(), .close_timeout = .fromSeconds(2) });
    defer client.deinit();
    var conn = try client.acquire(io, .of(.root));
    defer conn.release(io);
    try conn.run(io, .of(.root), cmd.watch(&.{"stock"}), .{});
    try testing.expectEqual(@as(?i64, 5), try conn.run(io, .of(.root), cmd.raw(?i64, .{ "GET", "stock" }), .{}));
    var closed: Io.Event = .unset;
    const start = time.now(io);
    var closing = try io.concurrent(closeThenSet, .{ &client, io, &closed });
    defer closing.cancel(io);
    // The close has begun, and waits for the Conn.
    try redis.testing.sleepAtLeast(io, .fromMilliseconds(100));
    try testing.expect(!closed.isSet());
    const done = try conn.transaction(io, .of(.root), .{cmd.raw(i64, .{ "DECR", "stock" })}, .{});
    const results = done orelse return error.TestExpectedResults;
    try testing.expectEqual(@as(i64, 4), try results[0]);
    conn.release(io);
    closing.await(io);
    try testing.expect(start.durationTo(time.now(io)).toMilliseconds() < 1500);
    try testing.expectEqual(@as(usize, 0), client.stats().connections);
    try server.finish(io);
}

test "a Conn not released holds close up for close_timeout, then its connection is cut: its calls are Closed, and release closes the connection" {
    try within5s(testing.io, closeCutsHeldConn, .{testing.io});
}

fn closeCutsHeldConn(io: Io) !void {
    var peer: Peer = try .listen(io);
    defer peer.close(io);
    var client: Client = try .init(testing.allocator, io, .{ .url = peer.url(), .close_timeout = .fromMilliseconds(300) });
    defer client.deinit();
    var connecting = try io.concurrent(Client.connect, .{ &client, io, core.Context.root, null });
    defer connecting.cancel(io) catch {};
    try peer.accept(io);
    try peers.shakeHands(&peer, io, .zero);
    try connecting.await(io);
    // The Conn takes the connection that connect opened.
    var conn = try client.acquire(io, .of(.root));
    defer conn.release(io);
    const start = time.now(io);
    client.close(io);
    try testing.expect(start.durationTo(time.now(io)).toMilliseconds() >= 300);
    // The cut shut the connection down: the peer reads its end.
    _ = try peer.readToEnd();
    var d: Diagnostics = .{};
    try testing.expectError(error.Closed, conn.run(io, .of(.root), get, .{ .diagnostics = &d }));
    try testing.expectEqualStrings("the client is closed", d.message());
    try testing.expectEqual(@as(usize, 1), client.stats().connections);
    conn.release(io);
    try testing.expectEqual(@as(usize, 0), client.stats().connections);
}
