//! The pool of the client against mongo-plain: 200 calls share
//! four connections, first come first served, and the pool comes back to
//! rest; a deadline or serverSelectionTimeoutMS that ends in line is
//! PoolExhausted; `close` sends the calls in line away, lets the calls in
//! flight end within close_timeout and cuts those that outlast it, also
//! with 1,000 calls at once.
//!
//! And against servers that fail: mongo-stall, paused, takes commands and
//! never answers, so a call out is Timeout and only its connection closes,
//! and a call in line is PoolExhausted; mongo-restart, restarted, drops
//! every connection, so a call on one is ConnectionLost and clears the
//! pool, and the call after it probes and finds the server back.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const core = @import("core");
const mongo = @import("mongo");
const bson = mongo.bson;
const e2e = @import("root.zig");

const ping: mongo.Command = .{ .database = "admin", .body = bson.literal(.{ .ping = 1 }) };

/// `sleep`, a test command of mongo-plain, without a lock, so that calls
/// on several connections sleep at once: the call holds its connection
/// for `millis`.
fn sleepFor(comptime millis: i32) mongo.Command {
    return .{ .database = "admin", .body = bson.literal(.{ .sleep = 1, .millis = millis, .lock = "none" }) };
}

fn within(io: Io, duration: Io.Duration) core.Context {
    return core.Context.root.withDeadline(.after(Io.Clock.awake.now(io), duration));
}

/// A client of mongo-plain with the options `query`, connected.
fn connected(io: Io, driver: *mongo.Client, buffer: []u8, query: []const u8, close_timeout: Io.Duration) !void {
    return connectedTo(io, driver, buffer, e2e.servers.plain_port, query, close_timeout);
}

/// A client of the server at `port` with the options `query`, connected.
fn connectedTo(io: Io, driver: *mongo.Client, buffer: []u8, port: u16, query: []const u8, close_timeout: Io.Duration) !void {
    const uri = try std.fmt.bufPrint(buffer, "mongodb://127.0.0.1:{d}/?appName=zefir-e2e-pool&{s}", .{ port, query });
    driver.* = try .init(testing.allocator, io, .{ .uri = uri, .close_timeout = close_timeout });
    errdefer driver.deinit();
    var d: mongo.Diagnostics = .{};
    driver.connect(io, within(io, .fromSeconds(10)), &d) catch |err| {
        std.debug.print("connect: {t}: {s}\n", .{ err, d.message() });
        return err;
    };
}

fn awaitStats(io: Io, driver: *mongo.Client, comptime field: []const u8, value: usize) !void {
    const give_up: core.Deadline = .after(Io.Clock.awake.now(io), .fromSeconds(20));
    while (@field(driver.stats(), field) != value) {
        if (give_up.isExpired(Io.Clock.awake.now(io))) return error.TestTimedOut;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}

/// Calls run in tasks of a group, which return nothing: each counts what
/// it got against what it expected.
const Calls = struct {
    c: *mongo.Client,
    /// Null: success.
    expected: ?mongo.Error = null,
    message: []const u8 = "",
    /// The deadline of each call, from its start.
    deadline: Io.Duration = .fromSeconds(10),
    finished: std.atomic.Value(usize) = .init(0),
    unexpected: std.atomic.Value(u32) = .init(0),

    fn run(calls: *Calls, io: Io, command: mongo.Command) void {
        defer _ = calls.finished.fetchAdd(1, .acq_rel);
        var d: mongo.Diagnostics = .{};
        const result = calls.c.runCommand(io, .of(within(io, calls.deadline)), command, .{ .allocator = testing.allocator, .diagnostics = &d });
        if (result) |reply| {
            reply.deinit();
            if (calls.expected == null) return;
        } else |err| if (calls.expected) |expected| {
            if (err == expected and std.mem.eql(u8, calls.message, d.message())) return;
        }
        _ = calls.unexpected.fetchAdd(1, .acq_rel);
        if (result) |_| std.debug.print("call: ok, and an error was expected\n", .{}) else |err| std.debug.print("call: {t}: {s}\n", .{ err, d.message() });
    }
};

test "200 calls ping through four connections, served first come first served, and the pool comes back to rest" {
    try e2e.onZio(firstComeFirstServed);
}

/// The calls in line: once a call has its connection, none of those that
/// joined the line before it waits any more.
const Line = struct {
    driver: *mongo.Client,
    count: usize,
    calls: Calls,
    overtaken: std.atomic.Value(u32) = .init(0),

    fn call(line: *Line, io: Io, place: usize) void {
        line.calls.run(io, ping);
        // The calls that wait came after this one.
        if (line.driver.stats().waiting > line.count - 1 - place) _ = line.overtaken.fetchAdd(1, .acq_rel);
    }
};

fn firstComeFirstServed(io: Io) !void {
    var driver: mongo.Client = undefined;
    var buffer: [160]u8 = undefined;
    try connected(io, &driver, &buffer, "maxPoolSize=4", .fromSeconds(5));
    defer driver.deinit();
    const c = &driver;
    // Four calls hold the four connections while the line forms.
    var holders: Calls = .{ .c = c };
    var holding: Io.Group = .init;
    defer holding.cancel(io);
    for (0..4) |_| try holding.concurrent(io, Calls.run, .{ &holders, io, sleepFor(2000) });
    try awaitStats(io, &driver, "in_use", 4);
    var line: Line = .{ .driver = &driver, .count = 200, .calls = .{ .c = c } };
    var waiting: Io.Group = .init;
    defer waiting.cancel(io);
    for (0..line.count) |place| {
        try waiting.concurrent(io, Line.call, .{ &line, io, place });
        // The next call joins the line behind this one.
        const give_up: core.Deadline = .after(Io.Clock.awake.now(io), .fromSeconds(20));
        while (driver.stats().waiting + line.calls.finished.load(.acquire) < place + 1) {
            if (give_up.isExpired(Io.Clock.awake.now(io))) return error.TestTimedOut;
            try io.sleep(.fromMilliseconds(1), .awake);
        }
    }
    // Never more than four connections, open or opening.
    var peak: usize = 0;
    while (line.calls.finished.load(.acquire) < line.count) {
        const stats = driver.stats();
        peak = @max(peak, stats.connections + stats.opening);
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    try waiting.await(io);
    try holding.await(io);
    try testing.expectEqual(@as(u32, 0), holders.unexpected.load(.acquire));
    try testing.expectEqual(@as(u32, 0), line.calls.unexpected.load(.acquire));
    try testing.expectEqual(@as(u32, 0), line.overtaken.load(.acquire));
    try testing.expect(peak <= 4);
    const stats = driver.stats();
    try testing.expectEqual(@as(usize, 4), stats.connections);
    try testing.expectEqual(stats.connections, stats.idle);
    try testing.expectEqual(@as(usize, 0), stats.in_use + stats.waiting + stats.opening);
    try testing.expectEqual(@as(u64, 0), stats.clears);
}

test "a deadline that ends in line is PoolExhausted, and so is serverSelectionTimeoutMS for a call without one" {
    try e2e.onZio(exhausted);
}

fn exhausted(io: Io) !void {
    var driver: mongo.Client = undefined;
    var buffer: [160]u8 = undefined;
    try connected(io, &driver, &buffer, "maxPoolSize=1&serverSelectionTimeoutMS=300", .fromSeconds(5));
    defer driver.deinit();
    const c = &driver;
    var holder: Calls = .{ .c = c };
    var holding: Io.Group = .init;
    defer holding.cancel(io);
    try holding.concurrent(io, Calls.run, .{ &holder, io, sleepFor(1500) });
    try awaitStats(io, &driver, "in_use", 1);
    var d: mongo.Diagnostics = .{};
    try testing.expectError(error.PoolExhausted, c.runCommand(io, .of(within(io, .fromMilliseconds(100))), ping, .{ .allocator = testing.allocator, .diagnostics = &d }));
    try testing.expectEqualStrings("the deadline passed while the call waited for a connection", d.message());
    try testing.expectEqual(mongo.Diagnostics.Phase.checkout, d.phase.?);
    try testing.expectError(error.PoolExhausted, c.runCommand(io, .of(.root), ping, .{ .allocator = testing.allocator, .diagnostics = &d }));
    try testing.expectEqualStrings("serverSelectionTimeoutMS passed while the call waited for a connection", d.message());
    try testing.expectEqual(@as(usize, 0), driver.stats().waiting);
    try holding.await(io);
    try testing.expectEqual(@as(u32, 0), holder.unexpected.load(.acquire));
}

test "close sends the calls in line away and cuts the calls in flight that outlast close_timeout" {
    try e2e.onZio(closeCuts);
}

fn closeCuts(io: Io) !void {
    var driver: mongo.Client = undefined;
    var buffer: [160]u8 = undefined;
    try connected(io, &driver, &buffer, "maxPoolSize=2", .fromMilliseconds(300));
    defer driver.deinit();
    const c = &driver;
    var in_flight: Calls = .{ .c = c, .expected = error.ConnectionLost, .message = "close() of the client cut the exchange" };
    var flying: Io.Group = .init;
    defer flying.cancel(io);
    for (0..2) |_| try flying.concurrent(io, Calls.run, .{ &in_flight, io, sleepFor(3000) });
    try awaitStats(io, &driver, "in_use", 2);
    var in_line: Calls = .{ .c = c, .expected = error.Closed, .message = "the client was closed while the call waited for a connection" };
    var waiting: Io.Group = .init;
    defer waiting.cancel(io);
    for (0..3) |_| try waiting.concurrent(io, Calls.run, .{ &in_line, io, ping });
    try awaitStats(io, &driver, "waiting", 3);
    const start = Io.Clock.awake.now(io);
    driver.close(io);
    const took = start.durationTo(Io.Clock.awake.now(io)).toMilliseconds();
    try testing.expect(took >= 300 and took < 2000);
    try flying.await(io);
    try waiting.await(io);
    try testing.expectEqual(@as(u32, 0), in_flight.unexpected.load(.acquire));
    try testing.expectEqual(@as(u32, 0), in_line.unexpected.load(.acquire));
    var d: mongo.Diagnostics = .{};
    try testing.expectError(error.Closed, c.runCommand(io, .of(.root), ping, .{ .allocator = testing.allocator, .diagnostics = &d }));
    try testing.expectEqualStrings("the client is closed", d.message());
    try testing.expectEqual(@as(usize, 0), driver.stats().connections);
}

test "close lets the calls in flight end within close_timeout" {
    try e2e.onZio(closeWaits);
}

fn closeWaits(io: Io) !void {
    var driver: mongo.Client = undefined;
    var buffer: [160]u8 = undefined;
    try connected(io, &driver, &buffer, "maxPoolSize=2", .fromSeconds(5));
    defer driver.deinit();
    const c = &driver;
    var in_flight: Calls = .{ .c = c };
    var flying: Io.Group = .init;
    defer flying.cancel(io);
    for (0..2) |_| try flying.concurrent(io, Calls.run, .{ &in_flight, io, sleepFor(300) });
    try awaitStats(io, &driver, "in_use", 2);
    driver.close(io);
    // Both ended well: close let them, within close_timeout.
    try flying.await(io);
    try testing.expectEqual(@as(u32, 0), in_flight.unexpected.load(.acquire));
    try testing.expectEqual(@as(usize, 0), driver.stats().connections);
}

test "close at 1,000 calls at once: the 900 in line are Closed at once, and the 100 on connections are cut at close_timeout" {
    try e2e.onZio(closeUnderLoad);
}

fn closeUnderLoad(io: Io) !void {
    var driver: mongo.Client = undefined;
    var buffer: [160]u8 = undefined;
    try connected(io, &driver, &buffer, "maxPoolSize=100", .fromMilliseconds(500));
    defer driver.deinit();
    const c = &driver;
    var in_flight: Calls = .{ .c = c, .expected = error.ConnectionLost, .message = "close() of the client cut the exchange", .deadline = .fromSeconds(30) };
    var flying: Io.Group = .init;
    defer flying.cancel(io);
    for (0..100) |_| try flying.concurrent(io, Calls.run, .{ &in_flight, io, sleepFor(5000) });
    try awaitStats(io, &driver, "in_use", 100);
    var in_line: Calls = .{ .c = c, .expected = error.Closed, .message = "the client was closed while the call waited for a connection", .deadline = .fromSeconds(30) };
    var waiting: Io.Group = .init;
    defer waiting.cancel(io);
    for (0..900) |_| try waiting.concurrent(io, Calls.run, .{ &in_line, io, ping });
    try awaitStats(io, &driver, "waiting", 900);
    const start = Io.Clock.awake.now(io);
    driver.close(io);
    const took = start.durationTo(Io.Clock.awake.now(io)).toMilliseconds();
    try flying.await(io);
    try waiting.await(io);
    try testing.expectEqual(@as(u32, 0), in_flight.unexpected.load(.acquire));
    try testing.expectEqual(@as(u32, 0), in_line.unexpected.load(.acquire));
    try testing.expectEqual(@as(usize, 100), in_flight.finished.load(.acquire));
    try testing.expectEqual(@as(usize, 900), in_line.finished.load(.acquire));
    testing.expect(took >= 500 and took < 3000) catch |err| {
        std.debug.print("close took {d} ms\n", .{took});
        return err;
    };
    const stats = driver.stats();
    try testing.expectEqual(@as(usize, 0), stats.connections + stats.opening + stats.waiting);
}

/// A ping that must succeed.
fn pingOk(io: Io, c: *mongo.Client) !void {
    var d: mongo.Diagnostics = .{};
    const reply = c.runCommand(io, .of(within(io, .fromSeconds(10))), ping, .{ .allocator = testing.allocator, .diagnostics = &d }) catch |err| {
        std.debug.print("ping: {t}: {s}\n", .{ err, d.message() });
        return err;
    };
    reply.deinit();
}

/// 16 pings at once, which must all succeed: the pool serves again.
fn pingsOk(io: Io, c: *mongo.Client) !void {
    var calls: Calls = .{ .c = c };
    var group: Io.Group = .init;
    defer group.cancel(io);
    for (0..16) |_| try group.concurrent(io, Calls.run, .{ &calls, io, ping });
    try group.await(io);
    try testing.expectEqual(@as(u32, 0), calls.unexpected.load(.acquire));
}

test "a paused server: a call out is Timeout and closes only its connection, a call in line is PoolExhausted, a connection that cannot open is Unavailable with the labels of overload, and calls go through once it answers again" {
    try e2e.onZio(pausedServer);
}

fn pausedServer(io: Io) !void {
    var driver: mongo.Client = undefined;
    var buffer: [160]u8 = undefined;
    try connectedTo(io, &driver, &buffer, e2e.servers.stall_port, "maxPoolSize=1&connectTimeoutMS=300", .fromSeconds(5));
    defer driver.deinit();
    const c = &driver;
    try pingOk(io, c);

    // mongod takes what comes and answers nothing.
    try e2e.docker(&.{ "pause", e2e.servers.stall_container });
    errdefer e2e.unpause(e2e.servers.stall_container) catch {};
    var out: Calls = .{ .c = c, .expected = error.Timeout, .message = "the deadline passed before the reply came", .deadline = .fromMilliseconds(1500) };
    var flying: Io.Group = .init;
    defer flying.cancel(io);
    try flying.concurrent(io, Calls.run, .{ &out, io, ping });
    try awaitStats(io, &driver, "in_use", 1);
    // The only connection is out: a call whose deadline passes in line.
    var d: mongo.Diagnostics = .{};
    try testing.expectError(error.PoolExhausted, c.runCommand(io, .of(within(io, .fromMilliseconds(300))), ping, .{ .allocator = testing.allocator, .diagnostics = &d }));
    try testing.expectEqualStrings("the deadline passed while the call waited for a connection", d.message());
    try flying.await(io);
    try testing.expectEqual(@as(u32, 0), out.unexpected.load(.acquire));
    // The timeout closed its connection, and cleared nothing.
    var stats = driver.stats();
    try testing.expectEqual(@as(usize, 0), stats.connections + stats.opening + stats.waiting);
    try testing.expectEqual(@as(u64, 0), stats.clears);

    // A new connection gets no answer to hello: within connectTimeoutMS
    // it is Unavailable, with the labels that CMAP gives a server that
    // may be overloaded, and within a shorter deadline DeadlineExceeded.
    try testing.expectError(error.Unavailable, c.runCommand(io, .of(.root), ping, .{ .allocator = testing.allocator, .diagnostics = &d }));
    var expected: [96]u8 = undefined;
    try testing.expectEqualStrings(try std.fmt.bufPrint(&expected, "127.0.0.1:{d} did not answer within connectTimeoutMS (300 ms)", .{e2e.servers.stall_port}), d.message());
    try testing.expectEqual(mongo.Diagnostics.Phase.connect, d.phase.?);
    try testing.expectEqual(@as(i32, 0), d.server.?.code);
    try testing.expect(d.server.?.labels.contains(.system_overloaded_error));
    try testing.expect(d.server.?.labels.contains(.retryable_error));
    try testing.expectError(error.DeadlineExceeded, c.runCommand(io, .of(within(io, .fromMilliseconds(100))), ping, .{ .allocator = testing.allocator, .diagnostics = &d }));
    try testing.expectEqualStrings(try std.fmt.bufPrint(&expected, "the deadline passed while the client connected to 127.0.0.1:{d}", .{e2e.servers.stall_port}), d.message());
    stats = driver.stats();
    try testing.expectEqual(@as(usize, 0), stats.connections + stats.opening);
    try testing.expectEqual(@as(u64, 0), stats.clears);

    try e2e.unpause(e2e.servers.stall_container);
    try pingOk(io, c);
    stats = driver.stats();
    try testing.expectEqual(@as(usize, 1), stats.connections);
    try testing.expectEqual(@as(u64, 0), stats.clears);
}

/// A call of `sleep` for 10 s, out when the server restarts, and how it
/// ended.
const CallOut = struct {
    c: *mongo.Client,
    result: mongo.Error!void = {},
    d: mongo.Diagnostics = .{},

    fn run(out: *CallOut, io: Io) void {
        const reply = out.c.runCommand(io, .of(within(io, .fromSeconds(30))), sleepFor(10_000), .{ .allocator = testing.allocator, .diagnostics = &out.d }) catch |err| {
            out.result = err;
            return;
        };
        reply.deinit();
    }
};

/// Two connections of `c`, idle: two calls that sleep at once.
fn twoIdle(io: Io, c: *mongo.Client) !void {
    var holders: Calls = .{ .c = c };
    var group: Io.Group = .init;
    defer group.cancel(io);
    for (0..2) |_| try group.concurrent(io, Calls.run, .{ &holders, io, sleepFor(300) });
    try group.await(io);
    try testing.expectEqual(@as(u32, 0), holders.unexpected.load(.acquire));
    try testing.expectEqual(@as(usize, 2), c.stats().idle);
}

/// The pool after a clear by a server that went: one clear, a new
/// generation, and no connection of the old one left.
fn expectCleared(c: *mongo.Client) !void {
    const stats = c.stats();
    try testing.expectEqual(@as(u64, 1), stats.clears);
    try testing.expectEqual(@as(u64, 1), stats.generation);
    try testing.expectEqual(@as(usize, 0), stats.connections + stats.opening);
}

test "a restart ends the call out, by a cut or by InterruptedAtShutdown, which clears the pool; the next call probes, opens a connection, and the pool serves again" {
    try e2e.onZio(restartWithCallOut);
}

fn restartWithCallOut(io: Io) !void {
    var driver: mongo.Client = undefined;
    var buffer: [160]u8 = undefined;
    try connectedTo(io, &driver, &buffer, e2e.servers.restart_port, "maxPoolSize=3", .fromSeconds(5));
    defer driver.deinit();
    const c = &driver;
    try twoIdle(io, c);
    var out: CallOut = .{ .c = c };
    var flying = try io.concurrent(CallOut.run, .{ &out, io });
    defer flying.cancel(io);
    try awaitStats(io, &driver, "in_use", 1);
    try e2e.restart(e2e.servers.restart_container);
    flying.await(io);
    if (out.result) |_| {
        std.debug.print("the call out ended well\n", .{});
        return error.TestUnexpectedResult;
    } else |err| switch (err) {
        error.ConnectionLost => {},
        error.CommandFailed => {
            const code = out.d.server.?.code;
            if (code != 11600 and code != 91) {
                std.debug.print("the call out: CommandFailed {d}: {s}\n", .{ code, out.d.message() });
                return error.TestUnexpectedResult;
            }
        },
        else => {
            std.debug.print("the call out: {t}: {s}\n", .{ err, out.d.message() });
            return err;
        },
    }
    try expectCleared(c);
    // The pool is paused: the next call is its probe, and finds the server
    // back.
    try pingOk(io, c);
    try testing.expectEqual(@as(usize, 1), driver.stats().connections);
    try pingsOk(io, c);
    try testing.expectEqual(@as(u64, 1), driver.stats().clears);
}

test "after a restart the idle connections are dead: the next call is ConnectionLost and clears the pool, and the call after it probes and finds the server back" {
    try e2e.onZio(restartWithIdle);
}

fn restartWithIdle(io: Io) !void {
    var driver: mongo.Client = undefined;
    var buffer: [160]u8 = undefined;
    try connectedTo(io, &driver, &buffer, e2e.servers.restart_port, "maxPoolSize=3", .fromSeconds(5));
    defer driver.deinit();
    const c = &driver;
    try twoIdle(io, c);
    try e2e.restart(e2e.servers.restart_container);
    var d: mongo.Diagnostics = .{};
    const lost = c.runCommand(io, .of(within(io, .fromSeconds(10))), ping, .{ .allocator = testing.allocator, .diagnostics = &d });
    if (lost) |reply| {
        reply.deinit();
        std.debug.print("a ping on a connection of the mongod before the restart went through\n", .{});
        return error.TestUnexpectedResult;
    } else |err| testing.expectEqual(error.ConnectionLost, err) catch |e| {
        std.debug.print("the first ping: {t}: {s}\n", .{ err, d.message() });
        return e;
    };
    try expectCleared(c);
    try pingOk(io, c);
    try testing.expectEqual(@as(usize, 1), driver.stats().connections);
    try pingsOk(io, c);
    try testing.expectEqual(@as(u64, 1), driver.stats().clears);
}
