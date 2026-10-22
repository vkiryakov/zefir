//! Tests of the client's life on its pool, against
//! `redis.testing.FakeServer` over loopback: `close` lets the calls in
//! flight end within `close_timeout` and cuts those that outlast it, sends
//! away the calls in line and those that come after it, and keeps the
//! cancelation of its task; a second `close` waits for the first; `stats`
//! tells what the pool holds. The calls in flight during `close` run on
//! the `Io` of `windows_like_io.zig` too, where a shutdown of a socket
//! does not end the read that waits on it. Every test runs under a time
//! limit of 5 s.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const core = @import("core");
const redis = @import("../root.zig");
const cmd = redis.cmd;
const Client = redis.Client;
const Diagnostics = redis.Diagnostics;
const FakeServer = redis.testing.FakeServer;
const Pool = @import("../engine/Pool.zig");
const time = @import("../engine/time.zig");
const WindowsLike = @import("windows_like_io.zig").WindowsLike;
const within5s = @import("time_limit.zig").within5s;

const get = cmd.raw(?i64, .{ "GET", "k" });

const seven: FakeServer.Reply = .{ .integer = 7 };

fn after(comptime ms: i64) FakeServer.Reply {
    return .{ .delayed = .{ .after = .fromMilliseconds(ms), .reply = &seven } };
}

fn within(io: Io, duration: Io.Duration) redis.OperationContext {
    return .of(core.Context.root.withDeadline(.after(time.now(io), duration)));
}

/// Runs `get` and expects `expected`: the reply 7 when null, else that
/// error with `message`.
fn call(io: Io, client: *Client, op: redis.OperationContext, expected: ?redis.Error, message: []const u8) !void {
    var d: Diagnostics = .{};
    const result = client.run(io, op, get, .{ .diagnostics = &d });
    if (expected) |err| {
        try testing.expectError(err, result);
        try testing.expectEqualStrings(message, d.message());
    } else try testing.expectEqual(@as(?i64, 7), try result);
}

/// Calls in the tasks of a group, which return nothing: each counts a
/// call whose reply was not 7.
const Calls = struct {
    client: *Client,
    failed: std.atomic.Value(u32) = .init(0),

    fn run(calls: *Calls, io: Io) void {
        call(io, calls.client, .of(.root), null, "") catch {
            _ = calls.failed.fetchAdd(1, .acq_rel);
        };
    }
};

fn awaitReceived(io: Io, server: *FakeServer, count: usize) !void {
    const give_up: core.Deadline = .after(time.now(io), .fromSeconds(4));
    while (server.received(io) != count) {
        if (time.expired(io, give_up)) return error.TestTimedOut;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}

fn awaitStats(io: Io, client: *Client, comptime field: []const u8, value: usize) !void {
    const give_up: core.Deadline = .after(time.now(io), .fromSeconds(4));
    while (@field(client.stats(), field) != value) {
        if (time.expired(io, give_up)) return error.TestTimedOut;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}

/// Waits until `close` of `client` has begun.
fn awaitClosing(io: Io, client: *Client) !void {
    const give_up: core.Deadline = .after(time.now(io), .fromSeconds(4));
    while (true) {
        client.pool.mutex.lockUncancelable(io);
        const state = client.pool.state;
        client.pool.mutex.unlock(io);
        if (state == .closing or state == .closed) return;
        if (time.expired(io, give_up)) return error.TestTimedOut;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}

test "a call in flight that outlasts close_timeout is cut: ConnectionLost, and close returns soon after it; calls after it are Closed, also where a shutdown does not end a read" {
    var windows: WindowsLike = undefined;
    for ([_]Io{ testing.io, windows.io() }) |io| try within5s(testing.io, closeCuts, .{io});
}

/// The client on `io`, the server on `std.testing.io`.
fn closeCuts(io: Io) !void {
    var server: FakeServer = try .start(testing.allocator, testing.io, &.{.expect(.{ "GET", "k" }, after(1000))});
    defer server.stop(testing.io);
    var client: Client = try .init(testing.allocator, io, .{ .url = server.url(), .close_timeout = .fromMilliseconds(100) });
    defer client.deinit();
    try client.connect(io, .root, null);
    var out = try io.concurrent(call, .{ io, &client, redis.OperationContext.of(.root), error.ConnectionLost, "close() of the client cut the exchange" });
    defer out.cancel(io) catch {};
    try awaitReceived(testing.io, &server, 1);
    const start = time.now(io);
    client.close(io);
    const took = start.durationTo(time.now(io)).toMilliseconds();
    try out.await(io);
    try testing.expect(took >= 100 and took < 1000);
    try call(io, &client, .of(.root), error.Closed, "the client is closed");
    try testing.expectEqual(@as(usize, 0), client.stats().connections);
}

test "a call in flight during close ends by its reply within close_timeout, or by its deadline, also where a shutdown does not end a read" {
    var windows: WindowsLike = undefined;
    for ([_]Io{ testing.io, windows.io() }) |io| try within5s(testing.io, closeWaits, .{io});
}

fn closeWaits(io: Io) !void {
    var server: FakeServer = try .start(testing.allocator, testing.io, &.{
        .expect(.{ "GET", "k" }, after(100)),
        .expect(.{ "GET", "k" }, after(1000)),
    });
    defer server.stop(testing.io);
    var client: Client = try .init(testing.allocator, io, .{ .url = server.url(), .close_timeout = .fromSeconds(3) });
    defer client.deinit();
    try client.connect(io, .root, null);
    var replied = try io.concurrent(call, .{ io, &client, redis.OperationContext.of(.root), null, "" });
    defer replied.cancel(io) catch {};
    try awaitReceived(testing.io, &server, 1);
    var timed_out = try io.concurrent(call, .{ io, &client, within(io, .fromMilliseconds(200)), error.Timeout, "the deadline passed before the reply came" });
    defer timed_out.cancel(io) catch {};
    try awaitReceived(testing.io, &server, 2);
    const start = time.now(io);
    client.close(io);
    // close waited for both, not for close_timeout.
    try testing.expect(start.durationTo(time.now(io)).toMilliseconds() < 1000);
    try replied.await(io);
    try timed_out.await(io);
    try testing.expectEqual(@as(usize, 0), client.stats().connections);
}

test "the calls in line for a connection are Closed when close begins" {
    try within5s(testing.io, closeSendsAway, .{testing.io});
}

fn closeSendsAway(io: Io) !void {
    var server: FakeServer = try .start(testing.allocator, io, &.{.expect(.{ "GET", "k" }, after(300))});
    defer server.stop(io);
    var client: Client = try .init(testing.allocator, io, .{ .url = server.url(), .max_connections = 1, .close_timeout = .fromSeconds(3) });
    defer client.deinit();
    try client.connect(io, .root, null);
    var holder = try io.concurrent(call, .{ io, &client, redis.OperationContext.of(.root), null, "" });
    defer holder.cancel(io) catch {};
    try awaitReceived(io, &server, 1);
    var waiter = try io.concurrent(call, .{ io, &client, redis.OperationContext.of(.root), error.Closed, "the client was closed while the call waited for a connection" });
    defer waiter.cancel(io) catch {};
    try awaitStats(io, &client, "waiting", 1);
    var closing = try io.concurrent(Client.close, .{ &client, io });
    defer closing.cancel(io);
    try waiter.await(io);
    try holder.await(io);
    closing.await(io);
    try testing.expectEqual(@as(usize, 1), server.received(io));
}

test "a second close from another task returns once the first is done, and one after it at once" {
    try within5s(testing.io, closeTwice, .{testing.io});
}

fn closeTwice(io: Io) !void {
    var server: FakeServer = try .start(testing.allocator, io, &.{.expect(.{ "GET", "k" }, after(200))});
    defer server.stop(io);
    var client: Client = try .init(testing.allocator, io, .{ .url = server.url(), .close_timeout = .fromSeconds(3) });
    defer client.deinit();
    try client.connect(io, .root, null);
    var out = try io.concurrent(call, .{ io, &client, redis.OperationContext.of(.root), null, "" });
    defer out.cancel(io) catch {};
    try awaitReceived(io, &server, 1);
    var first = try io.concurrent(Client.close, .{ &client, io });
    defer first.cancel(io);
    try awaitClosing(io, &client);
    client.close(io);
    // The second returned once the first was done, and that waited for
    // the call: no call is left, nor any connection.
    client.pool.mutex.lockUncancelable(io);
    const state = client.pool.state;
    const calls = client.pool.calls;
    client.pool.mutex.unlock(io);
    try testing.expectEqual(Pool.State.closed, state);
    try testing.expectEqual(@as(usize, 0), calls);
    first.await(io);
    try out.await(io);
    const start = time.now(io);
    client.close(io);
    try testing.expect(start.durationTo(time.now(io)).toMilliseconds() < 100);
}

test "close keeps the cancelation of its task for after it" {
    try within5s(testing.io, closeKeepsCancel, .{testing.io});
}

fn closeThenSleep(io: Io, client: *Client) !void {
    client.close(io);
    try testing.expectError(error.Canceled, io.sleep(.fromSeconds(5), .awake));
}

fn closeKeepsCancel(io: Io) !void {
    var server: FakeServer = try .start(testing.allocator, io, &.{.expect(.{ "GET", "k" }, after(200))});
    defer server.stop(io);
    var client: Client = try .init(testing.allocator, io, .{ .url = server.url(), .close_timeout = .fromSeconds(3) });
    defer client.deinit();
    try client.connect(io, .root, null);
    var out = try io.concurrent(call, .{ io, &client, redis.OperationContext.of(.root), null, "" });
    defer out.cancel(io) catch {};
    try awaitReceived(io, &server, 1);
    var closer = try io.concurrent(closeThenSleep, .{ io, &client });
    defer closer.cancel(io) catch {};
    try awaitClosing(io, &client);
    // close goes on to its end, and lets the call in flight end; the task
    // sees its cancelation after it.
    try closer.cancel(io);
    try out.await(io);
}

test "stats count the connections idle, in use and opening, the calls in line, the generation and the clears" {
    try within5s(testing.io, statsTell, .{testing.io});
}

fn statsTell(io: Io) !void {
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;
    var server: FakeServer = try .start(testing.allocator, io, &.{
        .expect(.{ "GET", "k" }, after(300)),
        .expect(.{ "GET", "k" }, after(300)),
        .expect(.{ "GET", "k" }, after(100)),
        .expect(.{ "GET", "k" }, .close_connection),
        .expect(.{ "GET", "k" }, seven),
    });
    defer server.stop(io);
    var client: Client = try .init(testing.allocator, io, .{ .url = server.url(), .max_connections = 2 });
    defer client.deinit();
    const none: Client.Stats = .{ .connections = 0, .idle = 0, .in_use = 0, .opening = 0, .waiting = 0, .subscribers = 0, .generation = 0, .clears = 0 };
    try testing.expectEqual(none, client.stats());
    try client.connect(io, .root, null);
    var expected = none;
    expected.connections = 1;
    expected.idle = 1;
    try testing.expectEqual(expected, client.stats());

    var calls: Calls = .{ .client = &client };
    var group: Io.Group = .init;
    defer group.cancel(io);
    for (0..2) |_| try group.concurrent(io, Calls.run, .{ &calls, io });
    try awaitReceived(io, &server, 2);
    try testing.expectEqual(Client.Stats{ .connections = 2, .idle = 0, .in_use = 2, .opening = 0, .waiting = 0, .subscribers = 0, .generation = 0, .clears = 0 }, client.stats());
    // A third call waits for one of the two.
    try group.concurrent(io, Calls.run, .{ &calls, io });
    try awaitStats(io, &client, "waiting", 1);
    try testing.expectEqual(Client.Stats{ .connections = 2, .idle = 0, .in_use = 2, .opening = 0, .waiting = 1, .subscribers = 0, .generation = 0, .clears = 0 }, client.stats());
    try group.await(io);
    try testing.expectEqual(@as(u32, 0), calls.failed.load(.acquire));
    expected.connections = 2;
    expected.idle = 2;
    try testing.expectEqual(expected, client.stats());

    // A connection that breaks clears the pool.
    try testing.expectError(error.ConnectionLost, client.run(io, .of(.root), get, .{}));
    expected = none;
    expected.generation = 1;
    expected.clears = 1;
    try testing.expectEqual(expected, client.stats());
    // The probe opens a connection of the new generation.
    try call(io, &client, .of(.root), null, "");
    expected.connections = 1;
    expected.idle = 1;
    try testing.expectEqual(expected, client.stats());
    client.close(io);
    expected.connections = 0;
    expected.idle = 0;
    try testing.expectEqual(expected, client.stats());
    try server.finish(io);
}
