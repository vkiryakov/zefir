//! The pool of the native driver against mongo-plain: 200 calls share
//! four connections, first come first served, and the pool comes back to
//! rest; a deadline or serverSelectionTimeoutMS that ends in line is
//! PoolExhausted; `close` sends the calls in line away, lets the calls in
//! flight end within close_timeout and cuts those that outlast it.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const core = @import("core");
const mongo = @import("mongo");
const native = mongo.native;
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
fn connected(io: Io, driver: *native.Client, buffer: []u8, query: []const u8, close_timeout: Io.Duration) !void {
    const uri = try std.fmt.bufPrint(buffer, "mongodb://127.0.0.1:{d}/?appName=zefir-e2e-pool&{s}", .{ e2e.servers.plain_port, query });
    driver.* = try .init(testing.allocator, io, .{ .uri = uri, .close_timeout = close_timeout });
    errdefer driver.deinit();
    var d: mongo.Diagnostics = .{};
    driver.connect(io, within(io, .fromSeconds(10)), &d) catch |err| {
        std.debug.print("connect: {t}: {s}\n", .{ err, d.message() });
        return err;
    };
}

fn awaitStats(io: Io, driver: *native.Client, comptime field: []const u8, value: usize) !void {
    const give_up: core.Deadline = .after(Io.Clock.awake.now(io), .fromSeconds(20));
    while (@field(driver.stats(), field) != value) {
        if (give_up.isExpired(Io.Clock.awake.now(io))) return error.TestTimedOut;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}

/// Calls run in tasks of a group, which return nothing: each counts what
/// it got against what it expected.
const Calls = struct {
    c: mongo.Client,
    /// Null: success.
    expected: ?mongo.Error = null,
    message: []const u8 = "",
    finished: std.atomic.Value(usize) = .init(0),
    unexpected: std.atomic.Value(u32) = .init(0),

    fn run(calls: *Calls, io: Io, command: mongo.Command) void {
        defer _ = calls.finished.fetchAdd(1, .acq_rel);
        var d: mongo.Diagnostics = .{};
        const result = calls.c.runCommand(io, .of(within(io, .fromSeconds(10))), command, .{ .allocator = testing.allocator, .diagnostics = &d });
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
    driver: *native.Client,
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
    var driver: native.Client = undefined;
    var buffer: [160]u8 = undefined;
    try connected(io, &driver, &buffer, "maxPoolSize=4", .fromSeconds(5));
    defer driver.deinit();
    const c = driver.client();
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
    var driver: native.Client = undefined;
    var buffer: [160]u8 = undefined;
    try connected(io, &driver, &buffer, "maxPoolSize=1&serverSelectionTimeoutMS=300", .fromSeconds(5));
    defer driver.deinit();
    const c = driver.client();
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
    var driver: native.Client = undefined;
    var buffer: [160]u8 = undefined;
    try connected(io, &driver, &buffer, "maxPoolSize=2", .fromMilliseconds(300));
    defer driver.deinit();
    const c = driver.client();
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
    var driver: native.Client = undefined;
    var buffer: [160]u8 = undefined;
    try connected(io, &driver, &buffer, "maxPoolSize=2", .fromSeconds(5));
    defer driver.deinit();
    const c = driver.client();
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
