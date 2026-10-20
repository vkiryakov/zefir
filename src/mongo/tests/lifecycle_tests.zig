//! Tests of the client's life on its pool, against
//! `mongo.testing.FakeServer` over loopback: `close` lets the calls in
//! flight end within `close_timeout` and cuts those that outlast it, sends
//! away the calls in line and those that come after it, stops a connection
//! being opened, and keeps the cancelation of its task; a second `close`
//! waits for the first. Every test runs under a time limit of 5 s. The
//! cuts and the stops run on the `Io` of `windows_like_io.zig` too, where a
//! shutdown of a socket does not end the read that waits on it.

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const testing = std.testing;
const core = @import("core");
const mongo = @import("../root.zig");
const bson = mongo.bson;
const Diagnostics = mongo.Diagnostics;
const FakeServer = mongo.testing.FakeServer;
const Script = mongo.testing.Script;
const Client = @import("../Client.zig");
const Stats = @import("../Stats.zig");
const Pool = @import("../engine/Pool.zig");
const time = @import("../engine/time.zig");
const within5s = @import("connection_tests.zig").within5s;
const WindowsLike = @import("windows_like_io.zig").WindowsLike;

const ping: mongo.Command = .{ .database = "admin", .body = bson.literal(.{ .ping = 1 }) };
const slow: mongo.Command = .{ .database = "admin", .body = bson.literal(.{ .slow = 1 }) };

/// A write done, whose write concern a server shutting down left
/// unsatisfied.
const concern_away = bson.literal(.{ .n = 1, .writeConcernError = .{ .code = 91, .codeName = "ShutdownInProgress", .errmsg = "the server is shutting down" }, .ok = 1.0 });

/// Answers `slow` after `delay`, `breakme` by closing the connection, an
/// insert into `away` and `concernaway` with `concern_away`, and anything
/// else with `{ok: 1.0}` at once.
const Slow = struct {
    delay: Io.Duration,

    pub fn answer(s: *Slow, io: Io, arena: std.mem.Allocator, request: *const Script.Request) Script.HandlerError!Script.Answer {
        _ = io;
        if (std.mem.eql(u8, request.name, "slow")) return .{ .delayed = .{ .after = s.delay, .reply = Script.ok } };
        if (std.mem.eql(u8, request.name, "breakme")) return .close_connection;
        if (std.mem.eql(u8, request.name, "concernaway")) return .{ .reply = concern_away };
        if (std.mem.eql(u8, request.name, "insert")) if (request.body.get("insert") catch null) |into| {
            if (into == .string and std.mem.eql(u8, into.string, "away")) return .{ .reply = concern_away };
        };
        if (std.mem.eql(u8, request.name, "goingaway")) {
            const code: i32 = if (request.body.get("code") catch null) |v| @intCast(v.asI64() catch 91) else 91;
            const name = if (code == 11600) "InterruptedAtShutdown" else "ShutdownInProgress";
            return .{ .reply = Script.failure(arena, .{ .code = code, .code_name = name, .errmsg = "the server is shutting down" }) catch return error.OutOfMemory };
        }
        return .{ .reply = Script.ok };
    }
};

/// A scripted server on loopback, served until `stop`.
const Served = struct {
    slow: Slow,
    script: Script,
    listener: net.Server,
    server: Io.Future(FakeServer.ServeError!void),
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
    const result = driver.runCommand(io, .of(.root), command, .{ .allocator = testing.allocator, .diagnostics = &d });
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
    defer call.cancel(io) catch {};
    try awaitReceived(io, &served.script, "slow", 1);
    var closing = try io.concurrent(Client.close, .{ &driver, io });
    defer closing.cancel(io);
    try awaitClosing(io, &driver);
    try run(io, &driver, ping, error.Closed, "the client is closed");
    try call.await(io);
    closing.await(io);
    try testing.expectEqual(@as(usize, 0), driver.stats().connections);
}

test "a call that outlasts close_timeout is cut: ConnectionLost, and close does not wait for its reply, also where a shutdown does not end a read" {
    var windows: WindowsLike = undefined;
    for ([_]Io{ testing.io, windows.io() }) |io| try within5s(testing.io, closeCuts, .{io});
}

/// The client on `io`, the server on `std.testing.io`.
fn closeCuts(io: Io) !void {
    var served: Served = undefined;
    try served.start(testing.io, .fromSeconds(3));
    defer served.stop(testing.io);
    var driver: Client = try .init(testing.allocator, io, .{ .uri = try served.uri(""), .close_timeout = .fromMilliseconds(50) });
    defer driver.deinit();
    try driver.connect(io, .root, null);
    var call = try io.concurrent(run, .{ io, &driver, slow, error.ConnectionLost, "close() of the client cut the exchange" });
    defer call.cancel(io) catch {};
    try awaitReceived(testing.io, &served.script, "slow", 1);
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
    defer holder.cancel(io) catch {};
    try awaitReceived(io, &served.script, "slow", 1);
    var waiter = try io.concurrent(run, .{ io, &driver, ping, error.Closed, "the client was closed while the call waited for a connection" });
    defer waiter.cancel(io) catch {};
    try awaitStats(io, &driver, "waiting", 1);
    var closing = try io.concurrent(Client.close, .{ &driver, io });
    defer closing.cancel(io);
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
    defer call.cancel(io) catch {};
    try awaitReceived(io, &served.script, "slow", 1);
    var first = try io.concurrent(Client.close, .{ &driver, io });
    defer first.cancel(io);
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
    defer call.cancel(io) catch {};
    try awaitReceived(io, &served.script, "slow", 1);
    var closer = try io.concurrent(closeThenSleep, .{ io, &driver });
    defer closer.cancel(io) catch {};
    try awaitClosing(io, &driver);
    // close goes on to its end; the sleep after it sees the cancelation.
    try closer.cancel(io);
    try call.await(io);
}

test "close stops a connection being opened, and connect is Closed, also where a shutdown does not end a read" {
    var windows: WindowsLike = undefined;
    for ([_]Io{ testing.io, windows.io() }) |io| try within5s(testing.io, closeStopsOpening, .{io});
}

/// Accepts one client, reads its hello, says so, and answers nothing nor
/// reads on until `done`: the end of the client's stream changes nothing.
fn hearHelloThenHold(io: Io, listener: *net.Server, heard: *Io.Event, done: *Io.Event) !void {
    var peer: FakeServer.Peer = undefined;
    try peer.accept(io, listener);
    defer peer.close();
    const request = (try peer.readRequest(testing.allocator)) orelse return error.TestUnexpectedResult;
    request.deinit();
    heard.set(io);
    try done.wait(io);
}

fn connectClosed(io: Io, driver: *Client) !void {
    var d: Diagnostics = .{};
    try testing.expectError(error.Closed, driver.connect(io, .root, &d));
    try testing.expectEqualStrings("the client was closed while it connected", d.message());
}

/// The client on `io`, the server on `std.testing.io`.
fn closeStopsOpening(io: Io) !void {
    var listener = try FakeServer.listen(testing.io);
    defer listener.deinit(testing.io);
    var heard: Io.Event = .unset;
    var done: Io.Event = .unset;
    var server = try testing.io.concurrent(hearHelloThenHold, .{ testing.io, &listener, &heard, &done });
    defer {
        done.set(testing.io);
        server.await(testing.io) catch {};
    }
    var buffer: [64]u8 = undefined;
    var driver: Client = try .init(testing.allocator, io, .{ .uri = try FakeServer.uri(&listener, &buffer) });
    defer driver.deinit();
    var connecting = try io.concurrent(connectClosed, .{ io, &driver });
    // A check that fails below returns: the task ends before the client
    // goes.
    defer connecting.cancel(io) catch {};
    // The opening waits for the reply to hello when the server has it.
    try heard.wait(testing.io);
    const start = time.now(io);
    driver.close(io);
    try testing.expect(start.durationTo(time.now(io)).toMilliseconds() < 1000);
    try connecting.await(io);
    try testing.expectEqual(@as(usize, 0), driver.stats().opening);
}

test "close stops a connection whose TCP connect or DNS lookup never ends, within close_timeout, and connect is Closed" {
    var windows: WindowsLike = undefined;
    for ([_]Io{ testing.io, windows.io() }) |base| {
        for ([_][]const u8{ "127.0.0.1", "localhost" }) |host| {
            var unreachable_: Unreachable = undefined;
            try within5s(testing.io, closeStopsDial, .{ unreachable_.io(base), host });
        }
    }
}

/// `base`, but its TCP connects and DNS lookups never end until their task
/// is canceled: a host that drops SYNs, a resolver that never answers. It
/// points into itself: `io` it in place.
const Unreachable = struct {
    vtable: Io.VTable,

    fn io(u: *Unreachable, base: Io) Io {
        u.vtable = base.vtable.*;
        u.vtable.netConnectIp = connectNever;
        u.vtable.netLookup = lookupNever;
        return .{ .userdata = base.userdata, .vtable = &u.vtable };
    }

    fn connectNever(userdata: ?*anyopaque, address: *const net.IpAddress, options: net.IpAddress.ConnectOptions) net.IpAddress.ConnectError!net.Socket {
        _ = address;
        _ = options;
        try holdUntilCanceled(userdata);
    }

    fn lookupNever(userdata: ?*anyopaque, host: net.HostName, resolved: *Io.Queue(net.HostName.LookupResult), options: net.HostName.LookupOptions) net.HostName.LookupError!void {
        _ = host;
        _ = options;
        // A lookup closes its queue when it returns.
        defer resolved.close(.{ .userdata = userdata, .vtable = testing.io.vtable });
        try holdUntilCanceled(userdata);
    }

    fn holdUntilCanceled(userdata: ?*anyopaque) Io.Cancelable!noreturn {
        while (true) try testing.io.vtable.sleep(userdata, .{ .duration = .{ .raw = .fromSeconds(3600), .clock = .awake } });
    }
};

/// The client on `io`, to `host`, which it never reaches.
fn closeStopsDial(io: Io, host: []const u8) !void {
    var buffer: [96]u8 = undefined;
    // Without the stop, close would wait for connectTimeoutMS.
    const uri = try std.fmt.bufPrint(&buffer, "mongodb://{s}:27017/?connectTimeoutMS=4000", .{host});
    var driver: Client = try .init(testing.allocator, io, .{ .uri = uri, .close_timeout = .fromSeconds(2) });
    defer driver.deinit();
    var connecting = try io.concurrent(connectClosed, .{ io, &driver });
    defer connecting.cancel(io) catch {};
    try awaitStats(io, &driver, "opening", 1);
    // The opening is in its connect or its lookup by now, or soon.
    try time.sleepUntil(io, .after(time.now(io), .fromMilliseconds(50)));
    const start = time.now(io);
    driver.close(io);
    const took = start.durationTo(time.now(io));
    try connecting.await(io);
    try testing.expect(took.toMilliseconds() < 1000);
    try testing.expectEqual(@as(usize, 0), driver.stats().opening);
}

test "stats count the connections idle, in use and opening, the calls in line, the generation and the clears" {
    try within5s(testing.io, statsTell, .{testing.io});
}

fn statsTell(io: Io) !void {
    var served: Served = undefined;
    try served.start(io, .fromMilliseconds(300));
    defer served.stop(io);
    var driver: Client = try .init(testing.allocator, io, .{ .uri = try served.uri("?maxPoolSize=1") });
    defer driver.deinit();
    const none: Stats = .{ .connections = 0, .idle = 0, .in_use = 0, .opening = 0, .waiting = 0, .generation = 0, .clears = 0, .open_cursors = 0 };
    try testing.expectEqual(none, driver.stats());
    try driver.connect(io, .root, null);
    var expected = none;
    expected.connections = 1;
    expected.idle = 1;
    try testing.expectEqual(expected, driver.stats());

    var holder = try io.concurrent(run, .{ io, &driver, slow, null, "" });
    defer holder.cancel(io) catch {};
    try awaitReceived(io, &served.script, "slow", 1);
    var waiter = try io.concurrent(run, .{ io, &driver, ping, null, "" });
    defer waiter.cancel(io) catch {};
    try awaitStats(io, &driver, "waiting", 1);
    try testing.expectEqual(Stats{ .connections = 1, .idle = 0, .in_use = 1, .opening = 0, .waiting = 1, .generation = 0, .clears = 0, .open_cursors = 0 }, driver.stats());
    try holder.await(io);
    try waiter.await(io);
    try testing.expectEqual(expected, driver.stats());

    // A connection that breaks clears the pool.
    try run(io, &driver, .{ .database = "admin", .body = bson.literal(.{ .breakme = 1 }) }, error.ConnectionLost, try std.fmt.bufPrint(&served.buffer, "the server at 127.0.0.1:{d} closed the connection", .{FakeServer.port(&served.listener)}));
    try testing.expectEqual(Stats{ .connections = 0, .idle = 0, .in_use = 0, .opening = 0, .waiting = 0, .generation = 1, .clears = 1, .open_cursors = 0 }, driver.stats());
    // The probe opens a connection of the new generation.
    try run(io, &driver, ping, null, "");
    try testing.expectEqual(Stats{ .connections = 1, .idle = 1, .in_use = 0, .opening = 0, .waiting = 0, .generation = 1, .clears = 1, .open_cursors = 0 }, driver.stats());
    driver.close(io);
    try testing.expectEqual(Stats{ .connections = 0, .idle = 0, .in_use = 0, .opening = 0, .waiting = 0, .generation = 1, .clears = 1, .open_cursors = 0 }, driver.stats());
}

test "a server that answers ShutdownInProgress or InterruptedAtShutdown clears the pool, and the next call opens anew" {
    try within5s(testing.io, shutdownClears, .{testing.io});
}

fn shutdownClears(io: Io) !void {
    var served: Served = undefined;
    try served.start(io, .zero);
    defer served.stop(io);
    var driver: Client = try .init(testing.allocator, io, .{ .uri = try served.uri("") });
    defer driver.deinit();
    try driver.connect(io, .root, null);
    for ([_]i32{ 91, 11600 }, 1..) |code, clears| {
        var d: Diagnostics = .{};
        const going: mongo.Command = .{ .database = "admin", .body = if (code == 91) bson.literal(.{ .goingaway = 1, .code = 91 }) else bson.literal(.{ .goingaway = 1, .code = 11600 }) };
        try testing.expectError(error.CommandFailed, driver.runCommand(io, .of(.root), going, .{ .allocator = testing.allocator, .diagnostics = &d }));
        try testing.expectEqual(code, d.server.?.code);
        const stats = driver.stats();
        try testing.expectEqual(@as(u64, clears), stats.clears);
        try testing.expectEqual(@as(usize, 0), stats.connections);
        // The probe: at most one every 500 ms.
        try time.sleepUntil(io, .after(time.now(io), .fromMilliseconds(500)));
        try run(io, &driver, ping, null, "");
    }
    try testing.expectEqual(@as(u32, 3), served.script.acceptedConnections());
}

test "a writeConcernError of a server shutting down clears the pool too, though the call itself succeeds" {
    try within5s(testing.io, shutdownConcernClears, .{testing.io});
}

fn shutdownConcernClears(io: Io) !void {
    var served: Served = undefined;
    try served.start(io, .zero);
    defer served.stop(io);
    var driver: Client = try .init(testing.allocator, io, .{ .uri = try served.uri("") });
    defer driver.deinit();
    try driver.connect(io, .root, null);
    // ok 1: the reply comes back as it is.
    const reply = try driver.runCommand(io, .of(.root), .{ .database = "admin", .body = bson.literal(.{ .concernaway = 1 }) }, .{ .allocator = testing.allocator });
    defer reply.deinit();
    try testing.expectEqualSlices(u8, concern_away.bytes, reply.bytes);
    try testing.expectEqual(@as(u64, 1), driver.stats().clears);
    try testing.expectEqual(@as(usize, 0), driver.stats().connections);
    // A write keeps the writeConcernError in its result.
    try time.sleepUntil(io, .after(time.now(io), Pool.probe_interval));
    const items = [_]bson.RawDocument{bson.literal(.{ ._id = 1 })};
    var result = try driver.write(io, .of(.root), .{ .database = "app", .kind = .insert, .body = bson.literal(.{ .insert = "away" }), .items = &items }, .{ .allocator = testing.allocator });
    defer result.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), result.write_concern_errors.len);
    try testing.expectEqual(@as(i32, 91), result.write_concern_errors[0].code);
    try testing.expectEqual(@as(u64, 2), driver.stats().clears);
    try testing.expectEqual(@as(usize, 0), driver.stats().connections);
}
