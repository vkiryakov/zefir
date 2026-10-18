//! Tests of the client's life on its pool, against
//! `mongo.testing.FakeServer` over loopback: `close` lets the calls in
//! flight end within `close_timeout` and cuts those that outlast it, sends
//! away the calls in line and those that come after it, stops a connection
//! being opened, and keeps the cancelation of its task; a second `close`
//! waits for the first. Every test runs under a time limit of 5 s.

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const testing = std.testing;
const core = @import("core");
const mongo = @import("mongo");
const bson = mongo.bson;
const Diagnostics = mongo.Diagnostics;
const FakeServer = mongo.testing.FakeServer;
const Script = mongo.testing.Script;
const Client = @import("../Client.zig");
const Pool = @import("../engine/Pool.zig");
const time = @import("../engine/time.zig");
const within5s = @import("connection_tests.zig").within5s;

const ping: mongo.Command = .{ .database = "admin", .body = bson.literal(.{ .ping = 1 }) };
const slow: mongo.Command = .{ .database = "admin", .body = bson.literal(.{ .slow = 1 }) };

/// Answers `slow` after `delay`, and anything else with `{ok: 1.0}` at
/// once.
const Slow = struct {
    delay: Io.Duration,

    pub fn answer(s: *Slow, io: Io, arena: std.mem.Allocator, request: *const Script.Request) Script.HandlerError!Script.Answer {
        _ = .{ io, arena };
        if (std.mem.eql(u8, request.name, "slow")) return .{ .delayed = .{ .after = s.delay, .reply = Script.ok } };
        return .{ .reply = Script.ok };
    }
};

/// A scripted server on loopback, served until `stop`.
const Served = struct {
    slow: Slow,
    script: Script,
    listener: net.Server,
    server: Io.Future(Io.Cancelable!void),
    buffer: [96]u8 = undefined,

    /// It points into itself: start it in place.
    fn start(s: *Served, io: Io, delay: Io.Duration) !void {
        s.* = .{ .slow = .{ .delay = delay }, .script = undefined, .listener = undefined, .server = undefined };
        s.script = .init(testing.allocator, .init(&s.slow));
        errdefer s.script.deinit();
        s.listener = try FakeServer.listen(io);
        errdefer s.listener.deinit(io);
        s.server = try io.concurrent(FakeServer.serve, .{ io, &s.listener, &s.script });
    }

    /// The server's URI with `query` after it, such as "?maxPoolSize=1".
    fn uri(s: *Served, query: []const u8) ![]const u8 {
        return std.fmt.bufPrint(&s.buffer, "mongodb://127.0.0.1:{d}/{s}", .{ FakeServer.port(&s.listener), query });
    }

    fn stop(s: *Served, io: Io) void {
        s.server.cancel(io) catch {};
        s.listener.deinit(io);
        s.script.deinit();
    }
};

/// Runs `command` and expects `expected`: success when null, else that
/// error with `message`.
fn run(io: Io, driver: *Client, command: mongo.Command, expected: ?mongo.Error, message: []const u8) !void {
    var d: Diagnostics = .{};
    const result = driver.client().runCommand(io, .of(.root), command, .{ .allocator = testing.allocator, .diagnostics = &d });
    if (expected) |err| {
        if (result) |reply| reply.deinit() else |_| {}
        try testing.expectError(err, result);
        try testing.expectEqualStrings(message, d.message());
    } else (try result).deinit();
}

fn awaitStats(io: Io, driver: *Client, comptime field: []const u8, value: usize) !void {
    const give_up: core.Deadline = .after(time.now(io), .fromSeconds(4));
    while (@field(driver.stats(), field) != value) {
        if (time.expired(io, give_up)) return error.TestTimedOut;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}

/// Waits until the server has `count` commands named `name`.
fn awaitReceived(io: Io, script: *Script, name: []const u8, count: usize) !void {
    const give_up: core.Deadline = .after(time.now(io), .fromSeconds(4));
    while (script.count(io, name) != count) {
        if (time.expired(io, give_up)) return error.TestTimedOut;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}

/// Waits until `close` of `driver` has begun: a call is Closed.
fn awaitClosing(io: Io, driver: *Client) !void {
    const give_up: core.Deadline = .after(time.now(io), .fromSeconds(4));
    while (true) {
        driver.pool.mutex.lockUncancelable(io);
        const state = driver.pool.state;
        driver.pool.mutex.unlock(io);
        if (state == .closing or state == .closed) return;
        if (time.expired(io, give_up)) return error.TestTimedOut;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}

test "close lets a call in flight end within close_timeout, and the calls that come meanwhile are Closed" {
    try within5s(testing.io, closeWaits, .{testing.io});
}

fn closeWaits(io: Io) !void {
    var served: Served = undefined;
    try served.start(io, .fromMilliseconds(300));
    defer served.stop(io);
    var driver: Client = try .init(testing.allocator, io, .{ .uri = try served.uri(""), .close_timeout = .fromSeconds(3) });
    defer driver.deinit();
    try driver.connect(io, .root, null);
    var call = try io.concurrent(run, .{ io, &driver, slow, null, "" });
    try awaitReceived(io, &served.script, "slow", 1);
    var closing = try io.concurrent(Client.close, .{ &driver, io });
    try awaitClosing(io, &driver);
    try run(io, &driver, ping, error.Closed, "the client is closed");
    try call.await(io);
    closing.await(io);
    try testing.expectEqual(@as(usize, 0), driver.stats().connections);
}

test "a call that outlasts close_timeout is cut: ConnectionLost, and close does not wait for its reply" {
    try within5s(testing.io, closeCuts, .{testing.io});
}

fn closeCuts(io: Io) !void {
    var served: Served = undefined;
    try served.start(io, .fromSeconds(3));
    defer served.stop(io);
    var driver: Client = try .init(testing.allocator, io, .{ .uri = try served.uri(""), .close_timeout = .fromMilliseconds(50) });
    defer driver.deinit();
    try driver.connect(io, .root, null);
    var call = try io.concurrent(run, .{ io, &driver, slow, error.ConnectionLost, "close() of the client cut the exchange" });
    try awaitReceived(io, &served.script, "slow", 1);
    const start = time.now(io);
    driver.close(io);
    try testing.expect(start.durationTo(time.now(io)).toMilliseconds() < 1000);
    try call.await(io);
    try testing.expectEqual(@as(usize, 0), driver.stats().connections);
}

test "the calls in line for a connection are Closed when close begins" {
    try within5s(testing.io, closeSendsAway, .{testing.io});
}

fn closeSendsAway(io: Io) !void {
    var served: Served = undefined;
    try served.start(io, .fromMilliseconds(300));
    defer served.stop(io);
    var driver: Client = try .init(testing.allocator, io, .{ .uri = try served.uri("?maxPoolSize=1"), .close_timeout = .fromSeconds(3) });
    defer driver.deinit();
    try driver.connect(io, .root, null);
    var holder = try io.concurrent(run, .{ io, &driver, slow, null, "" });
    try awaitReceived(io, &served.script, "slow", 1);
    var waiter = try io.concurrent(run, .{ io, &driver, ping, error.Closed, "the client was closed while the call waited for a connection" });
    try awaitStats(io, &driver, "waiting", 1);
    var closing = try io.concurrent(Client.close, .{ &driver, io });
    try waiter.await(io);
    try holder.await(io);
    closing.await(io);
}

test "a second close waits for the first to end, and one after it does nothing" {
    try within5s(testing.io, closeTwice, .{testing.io});
}

fn closeTwice(io: Io) !void {
    var served: Served = undefined;
    try served.start(io, .fromMilliseconds(200));
    defer served.stop(io);
    var driver: Client = try .init(testing.allocator, io, .{ .uri = try served.uri(""), .close_timeout = .fromSeconds(3) });
    defer driver.deinit();
    try driver.connect(io, .root, null);
    var call = try io.concurrent(run, .{ io, &driver, slow, null, "" });
    try awaitReceived(io, &served.script, "slow", 1);
    var first = try io.concurrent(Client.close, .{ &driver, io });
    try awaitClosing(io, &driver);
    driver.close(io);
    // The second returned once the first was done, and that waited for
    // the call: no call is left, nor any connection.
    driver.pool.mutex.lockUncancelable(io);
    const state = driver.pool.state;
    const calls = driver.pool.calls;
    driver.pool.mutex.unlock(io);
    try testing.expectEqual(Pool.State.closed, state);
    try testing.expectEqual(@as(usize, 0), calls);
    first.await(io);
    try call.await(io);
    const start = time.now(io);
    driver.close(io);
    try testing.expect(start.durationTo(time.now(io)).toMilliseconds() < 100);
}

test "close keeps the cancelation of its task for after it" {
    try within5s(testing.io, closeKeepsCancel, .{testing.io});
}

fn closeThenSleep(io: Io, driver: *Client) !void {
    driver.close(io);
    try testing.expectError(error.Canceled, io.sleep(.fromSeconds(5), .awake));
}

fn closeKeepsCancel(io: Io) !void {
    var served: Served = undefined;
    try served.start(io, .fromMilliseconds(200));
    defer served.stop(io);
    var driver: Client = try .init(testing.allocator, io, .{ .uri = try served.uri(""), .close_timeout = .fromSeconds(3) });
    defer driver.deinit();
    try driver.connect(io, .root, null);
    var call = try io.concurrent(run, .{ io, &driver, slow, null, "" });
    try awaitReceived(io, &served.script, "slow", 1);
    var closer = try io.concurrent(closeThenSleep, .{ io, &driver });
    try awaitClosing(io, &driver);
    // close goes on to its end; the sleep after it sees the cancelation.
    try closer.cancel(io);
    try call.await(io);
}

test "close stops a connection being opened, and connect is Closed" {
    try within5s(testing.io, closeStopsOpening, .{testing.io});
}

/// Accepts one client and reads until it goes, answering nothing.
fn holdSilent(io: Io, listener: *net.Server) !void {
    var peer: FakeServer.Peer = undefined;
    try peer.accept(io, listener);
    defer peer.close();
    _ = try peer.readToEnd();
}

fn connectClosed(io: Io, driver: *Client) !void {
    var d: Diagnostics = .{};
    try testing.expectError(error.Closed, driver.connect(io, .root, &d));
    try testing.expectEqualStrings("the client was closed while it connected", d.message());
}

fn closeStopsOpening(io: Io) !void {
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var server = try io.concurrent(holdSilent, .{ io, &listener });
    defer server.await(io) catch {};
    var buffer: [64]u8 = undefined;
    var driver: Client = try .init(testing.allocator, io, .{ .uri = try FakeServer.uri(&listener, &buffer) });
    defer driver.deinit();
    var connecting = try io.concurrent(connectClosed, .{ io, &driver });
    try awaitStats(io, &driver, "opening", 1);
    const start = time.now(io);
    driver.close(io);
    try testing.expect(start.durationTo(time.now(io)).toMilliseconds() < 1000);
    try connecting.await(io);
    try testing.expectEqual(@as(usize, 0), driver.stats().opening);
}
