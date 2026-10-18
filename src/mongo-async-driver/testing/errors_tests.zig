//! The table of `engine/errors.zig`, row by row, against
//! `mongo.testing.FakeServer` over loopback: where a call fails, the error
//! it gets, and what the failure leaves of the pool. A failed
//! authentication clears a ready pool; `pool_tests.zig` shows that on fake
//! connections, since the FakeServer has no users. Every test runs under a
//! time limit of 5 s.

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
const Stats = @import("../Stats.zig");
const time = @import("../engine/time.zig");
const within5s = @import("connection_tests.zig").within5s;

/// Answers each command by its name, as the rows need: `hold` after 3 s,
/// `drop` by closing the connection, `vanish` by closing it and refusing
/// new ones, `garble` with a reply that breaks OP_MSG, `refuse`, `expire`
/// and `shutdown` with ok 0 and codes 2, 50 and 91; the rest with
/// `{ok: 1.0}`.
const Rows = struct {
    pub fn answer(r: *Rows, io: Io, arena: std.mem.Allocator, request: *const Script.Request) Script.HandlerError!Script.Answer {
        _ = .{ r, io };
        const name = request.name;
        if (eql(name, "hold")) return .{ .delayed = .{ .after = .fromSeconds(3), .reply = Script.ok } };
        if (eql(name, "drop")) return .close_connection;
        if (eql(name, "vanish")) return .refuse_connections;
        if (eql(name, "garble")) return .{ .malformed = .truncated };
        const failure: ?Script.Failure = if (eql(name, "refuse"))
            .{ .code = 2, .code_name = "BadValue", .errmsg = "no good" }
        else if (eql(name, "expire"))
            .{ .code = 50, .code_name = "MaxTimeMSExpired", .errmsg = "operation exceeded time limit" }
        else if (eql(name, "shutdown"))
            .{ .code = 91, .code_name = "ShutdownInProgress", .errmsg = "the server is shutting down" }
        else
            null;
        if (failure) |f| return .{ .reply = Script.failure(arena, f) catch return error.OutOfMemory };
        return .{ .reply = Script.ok };
    }
};

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// A scripted server on loopback, served until `stop`.
const Served = struct {
    rows: Rows = .{},
    script: Script,
    listener: net.Server,
    server: Io.Future(Io.Cancelable!void),
    buffer: [96]u8 = undefined,

    /// It points into itself: start it in place.
    fn start(s: *Served, io: Io, hello: mongo.wire.Hello) !void {
        s.* = .{ .script = undefined, .listener = undefined, .server = undefined };
        s.script = .init(testing.allocator, .init(&s.rows));
        s.script.hello = hello;
        errdefer s.script.deinit();
        s.listener = try FakeServer.listen(io);
        errdefer s.listener.deinit(io);
        s.server = try io.concurrent(FakeServer.serve, .{ io, &s.listener, &s.script });
    }

    fn uri(s: *Served, query: []const u8) ![]const u8 {
        return std.fmt.bufPrint(&s.buffer, "mongodb://127.0.0.1:{d}/{s}", .{ FakeServer.port(&s.listener), query });
    }

    fn stop(s: *Served, io: Io) void {
        s.server.cancel(io) catch {};
        s.listener.deinit(io);
        s.script.deinit();
    }

    /// `driver`, a client of the server, connected where it is: a client
    /// does not move after connect.
    fn connect(s: *Served, io: Io, driver: *Client, query: []const u8) !void {
        driver.* = try .init(testing.allocator, io, .{ .uri = try s.uri(query) });
        errdefer driver.deinit();
        try driver.connect(io, .root, null);
    }
};

const ping: mongo.Command = .{ .database = "app", .body = bson.literal(.{ .ping = 1 }) };
const hold: mongo.Command = .{ .database = "app", .body = bson.literal(.{ .hold = 1 }) };
const drop: mongo.Command = .{ .database = "app", .body = bson.literal(.{ .drop = 1 }) };
const vanish: mongo.Command = .{ .database = "app", .body = bson.literal(.{ .vanish = 1 }) };
const garble: mongo.Command = .{ .database = "app", .body = bson.literal(.{ .garble = 1 }) };
const refuse: mongo.Command = .{ .database = "app", .body = bson.literal(.{ .refuse = 1 }) };
const expire: mongo.Command = .{ .database = "app", .body = bson.literal(.{ .expire = 1 }) };
const shutdown: mongo.Command = .{ .database = "app", .body = bson.literal(.{ .shutdown = 1 }) };

/// Runs `command` and expects `expected`, with the diagnostics it left.
fn expectFailure(io: Io, driver: *Client, op: mongo.OperationContext, command: mongo.Command, expected: mongo.Error, d: *Diagnostics) !void {
    const result = driver.client().runCommand(io, op, command, .{ .allocator = testing.allocator, .diagnostics = d });
    if (result) |reply| reply.deinit() else |_| {}
    try testing.expectError(expected, result);
}

fn within(io: Io, duration: Io.Duration) mongo.OperationContext {
    return .of(core.Context.root.withDeadline(.after(time.now(io), duration)));
}

fn awaitStats(io: Io, driver: *Client, comptime field: []const u8, value: usize) !void {
    const give_up: core.Deadline = .after(time.now(io), .fromSeconds(4));
    while (@field(driver.stats(), field) != value) {
        if (time.expired(io, give_up)) return error.TestTimedOut;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}

fn awaitReceived(io: Io, script: *Script, name: []const u8, count: usize) !void {
    const give_up: core.Deadline = .after(time.now(io), .fromSeconds(4));
    while (script.count(io, name) != count) {
        if (time.expired(io, give_up)) return error.TestTimedOut;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}

/// The connections, the clears and the generation of `stats`.
fn expectPool(stats: Stats, connections: usize, clears: u64) !void {
    try testing.expectEqual(connections, stats.connections);
    try testing.expectEqual(clears, stats.clears);
    try testing.expectEqual(clears, stats.generation);
}

test "before sending: less than 1 ms left of the deadline is DeadlineExceeded, nothing goes out, and the connection stays in the pool" {
    try within5s(testing.io, beforeSending, .{testing.io});
}

fn beforeSending(io: Io) !void {
    var served: Served = undefined;
    try served.start(io, .{});
    defer served.stop(io);
    var driver: Client = undefined;
    try served.connect(io, &driver, "");
    defer driver.deinit();
    var d: Diagnostics = .{};
    // The driver itself, behind the checks of mongo.Client.
    try testing.expectError(error.DeadlineExceeded, driver.runCommand(io, within(io, .fromMicroseconds(500)), &ping, .{ .allocator = testing.allocator, .diagnostics = &d }));
    try testing.expectEqualStrings("less than 1 ms was left of the deadline before the command went out", d.message());
    try testing.expectEqual(@as(usize, 0), served.script.received(io));
    try expectPool(driver.stats(), 1, 0);
    try testing.expectEqual(@as(usize, 1), driver.stats().idle);
}

test "checkout: a deadline that ends in line is PoolExhausted" {
    try within5s(testing.io, inLine, .{testing.io});
}

fn holdOne(io: Io, driver: *Client) void {
    const reply = driver.client().runCommand(io, .of(.root), hold, .{ .allocator = testing.allocator }) catch return;
    reply.deinit();
}

fn inLine(io: Io) !void {
    var served: Served = undefined;
    try served.start(io, .{});
    defer served.stop(io);
    var driver: Client = undefined;
    try served.connect(io, &driver, "?maxPoolSize=1");
    defer driver.deinit();
    var holder = try io.concurrent(holdOne, .{ io, &driver });
    defer holder.cancel(io);
    try awaitReceived(io, &served.script, "hold", 1);
    var d: Diagnostics = .{};
    try expectFailure(io, &driver, within(io, .fromMilliseconds(100)), ping, error.PoolExhausted, &d);
    try testing.expectEqualStrings("the deadline passed while the call waited for a connection", d.message());
    try testing.expectEqual(Diagnostics.Phase.checkout, d.phase.?);
}

test "checkout: before connect, and in a pool paused by a clear whose probe failed, a call is Unavailable; the opening that failed clears nothing" {
    try within5s(testing.io, unavailable, .{testing.io});
}

fn unavailable(io: Io) !void {
    var served: Served = undefined;
    try served.start(io, .{});
    defer served.stop(io);
    var d: Diagnostics = .{};
    {
        var driver: Client = try .init(testing.allocator, io, .{ .uri = try served.uri("") });
        defer driver.deinit();
        try expectFailure(io, &driver, .of(.root), ping, error.Unavailable, &d);
        try testing.expectEqualStrings("connect() has not succeeded", d.message());
    }
    var driver: Client = undefined;
    try served.connect(io, &driver, "");
    defer driver.deinit();
    // The server goes after the command, and refuses connections.
    try expectFailure(io, &driver, .of(.root), vanish, error.ConnectionLost, &d);
    try expectPool(driver.stats(), 0, 1);
    // The probe opens a connection, which the server closes at once.
    try expectFailure(io, &driver, .of(.root), ping, error.Unavailable, &d);
    try testing.expectEqual(Diagnostics.Phase.handshake, d.phase.?);
    const labels = d.server.?.labels;
    try testing.expect(labels.contains(.system_overloaded_error) and labels.contains(.retryable_error));
    try expectPool(driver.stats(), 0, 1);
    // The next probe may go 500 ms after it.
    try expectFailure(io, &driver, .of(.root), ping, error.Unavailable, &d);
    try testing.expect(std.mem.startsWith(u8, d.message(), "the pool is paused after a clear; the next probe may open a connection in "));
    try testing.expectEqual(Diagnostics.Phase.checkout, d.phase.?);
}

test "opening: a port where nothing listens is Unavailable with the labels of overload" {
    try within5s(testing.io, closedPort, .{testing.io});
}

fn closedPort(io: Io) !void {
    var listener = try FakeServer.listen(io);
    const port = FakeServer.port(&listener);
    listener.deinit(io);
    var buffer: [64]u8 = undefined;
    var driver: Client = try .init(testing.allocator, io, .{ .uri = try std.fmt.bufPrint(&buffer, "mongodb://127.0.0.1:{d}", .{port}) });
    defer driver.deinit();
    var d: Diagnostics = .{};
    try testing.expectError(error.Unavailable, driver.connect(io, .root, &d));
    try testing.expectEqual(Diagnostics.Phase.connect, d.phase.?);
    try testing.expect(std.mem.startsWith(u8, d.message(), "cannot connect to 127.0.0.1:"));
    try testing.expect(d.server.?.labels.contains(.system_overloaded_error));
    try expectPool(driver.stats(), 0, 0);
}

test "opening: the deadline of the call passing is DeadlineExceeded" {
    try within5s(testing.io, openingPastDeadline, .{testing.io});
}

/// Accepts one client and reads until it goes, answering nothing.
fn holdSilent(io: Io, listener: *net.Server) !void {
    var peer: FakeServer.Peer = undefined;
    try peer.accept(io, listener);
    defer peer.close();
    _ = try peer.readToEnd();
}

fn openingPastDeadline(io: Io) !void {
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var server = try io.concurrent(holdSilent, .{ io, &listener });
    defer server.await(io) catch {};
    var buffer: [64]u8 = undefined;
    var driver: Client = try .init(testing.allocator, io, .{ .uri = try FakeServer.uri(&listener, &buffer) });
    defer driver.deinit();
    var d: Diagnostics = .{};
    try testing.expectError(error.DeadlineExceeded, driver.connect(io, within(io, .fromMilliseconds(100)).ctx, &d));
    try testing.expectEqual(Diagnostics.Phase.connect, d.phase.?);
    try expectPool(driver.stats(), 0, 0);
}

test "opening: a server that is not a standalone mongod of MongoDB 7.0 or later is Unsupported" {
    try within5s(testing.io, wrongServer, .{testing.io});
}

fn wrongServer(io: Io) !void {
    for ([_]mongo.wire.Hello{ .{ .server_type = .rs_ghost }, .{ .max_wire_version = 20 } }) |hello| {
        var served: Served = undefined;
        try served.start(io, hello);
        defer served.stop(io);
        var driver: Client = try .init(testing.allocator, io, .{ .uri = try served.uri("") });
        defer driver.deinit();
        var d: Diagnostics = .{};
        try testing.expectError(error.Unsupported, driver.connect(io, .root, &d));
        try testing.expectEqual(Diagnostics.Phase.handshake, d.phase.?);
        try expectPool(driver.stats(), 0, 0);
    }
}

test "opening: SCRAM refused by the server is AuthenticationFailed" {
    try within5s(testing.io, refusedUser, .{testing.io});
}

fn refusedUser(io: Io) !void {
    var served: Served = undefined;
    try served.start(io, .{});
    defer served.stop(io);
    var buffer: [96]u8 = undefined;
    const uri = try std.fmt.bufPrint(&buffer, "mongodb://app:secret@127.0.0.1:{d}/", .{FakeServer.port(&served.listener)});
    var driver: Client = try .init(testing.allocator, io, .{ .uri = uri });
    defer driver.deinit();
    var d: Diagnostics = .{};
    try testing.expectError(error.AuthenticationFailed, driver.connect(io, .root, &d));
    try testing.expectEqual(Diagnostics.Phase.authenticate, d.phase.?);
    try testing.expectEqual(@as(i32, 18), d.server.?.code);
}

test "exchange: the server closing the connection after the command went out is ConnectionLost, and clears the pool" {
    try within5s(testing.io, lost, .{testing.io});
}

fn lost(io: Io) !void {
    var served: Served = undefined;
    try served.start(io, .{});
    defer served.stop(io);
    var driver: Client = undefined;
    try served.connect(io, &driver, "");
    defer driver.deinit();
    var d: Diagnostics = .{};
    try expectFailure(io, &driver, .of(.root), drop, error.ConnectionLost, &d);
    try testing.expectEqual(Diagnostics.Phase.wait, d.phase.?);
    try expectPool(driver.stats(), 0, 1);
}

test "exchange: the deadline passing while the command is out is Timeout, and closes its connection only" {
    try within5s(testing.io, timedOut, .{testing.io});
}

fn timedOut(io: Io) !void {
    var served: Served = undefined;
    try served.start(io, .{});
    defer served.stop(io);
    var driver: Client = undefined;
    try served.connect(io, &driver, "");
    defer driver.deinit();
    var d: Diagnostics = .{};
    try expectFailure(io, &driver, within(io, .fromMilliseconds(100)), hold, error.Timeout, &d);
    try testing.expectEqualStrings("the deadline passed before the reply came", d.message());
    try testing.expectEqual(Diagnostics.Phase.wait, d.phase.?);
    try expectPool(driver.stats(), 0, 0);
}

test "exchange: the task canceled while the command is out is Interrupted, the task stays canceled, and its connection closes only" {
    try within5s(testing.io, interrupted, .{testing.io});
}

fn holdAndKeep(io: Io, driver: *Client) !void {
    var d: Diagnostics = .{};
    try expectFailure(io, driver, .of(.root), hold, error.Interrupted, &d);
    try testing.expectEqualStrings("the task was canceled while the command was out", d.message());
    try testing.expectError(error.Canceled, io.checkCancel());
}

fn interrupted(io: Io) !void {
    var served: Served = undefined;
    try served.start(io, .{});
    defer served.stop(io);
    var driver: Client = undefined;
    try served.connect(io, &driver, "");
    defer driver.deinit();
    var holder = try io.concurrent(holdAndKeep, .{ io, &driver });
    try awaitReceived(io, &served.script, "hold", 1);
    try holder.cancel(io);
    try expectPool(driver.stats(), 0, 0);
}

test "reply: a reply that breaks OP_MSG is ProtocolViolation, and closes its connection only" {
    try within5s(testing.io, garbled, .{testing.io});
}

fn garbled(io: Io) !void {
    var served: Served = undefined;
    try served.start(io, .{});
    defer served.stop(io);
    var driver: Client = undefined;
    try served.connect(io, &driver, "");
    defer driver.deinit();
    var d: Diagnostics = .{};
    try expectFailure(io, &driver, .of(.root), garble, error.ProtocolViolation, &d);
    try testing.expectEqual(Diagnostics.Phase.receive, d.phase.?);
    try expectPool(driver.stats(), 0, 0);
}

test "reply: ok 0 is CommandFailed and code 50 is Timeout, both with the reply in failure_reply and the connection kept; code 91 clears the pool" {
    try within5s(testing.io, refused, .{testing.io});
}

fn refused(io: Io) !void {
    var served: Served = undefined;
    try served.start(io, .{});
    defer served.stop(io);
    var driver: Client = undefined;
    try served.connect(io, &driver, "");
    defer driver.deinit();
    const cases = [_]struct { mongo.Command, mongo.Error, i32, u64 }{
        .{ refuse, error.CommandFailed, 2, 0 },
        .{ expire, error.Timeout, 50, 0 },
        .{ shutdown, error.CommandFailed, 91, 1 },
    };
    for (cases) |case| {
        const command, const expected, const code, const clears = case;
        var d: Diagnostics = .{};
        var failure: ?bson.OwnedDocument = null;
        const result = driver.client().runCommand(io, .of(.root), command, .{ .allocator = testing.allocator, .diagnostics = &d, .failure_reply = &failure });
        if (result) |reply| reply.deinit() else |_| {}
        defer if (failure) |f| f.deinit();
        try testing.expectError(expected, result);
        try testing.expectEqual(code, d.server.?.code);
        try testing.expectEqual(Diagnostics.Phase.receive, d.phase.?);
        try testing.expectEqual(code, @as(i32, @intCast(try (try failure.?.raw().get("code")).?.asI64())));
        try expectPool(driver.stats(), if (clears == 0) 1 else 0, clears);
    }
}

test "after close every call is Closed" {
    try within5s(testing.io, afterClose, .{testing.io});
}

fn afterClose(io: Io) !void {
    var served: Served = undefined;
    try served.start(io, .{});
    defer served.stop(io);
    var driver: Client = undefined;
    try served.connect(io, &driver, "");
    defer driver.deinit();
    driver.close(io);
    var d: Diagnostics = .{};
    try expectFailure(io, &driver, .of(.root), ping, error.Closed, &d);
    try testing.expectEqualStrings("the client is closed", d.message());
    try testing.expectEqual(Diagnostics.Phase.checkout, d.phase.?);
}
