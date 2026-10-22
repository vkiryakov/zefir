//! The pool of the client against servers that fail, on the image that
//! REDIS_IMAGE names:
//!
//! - redis-stall, paused, takes commands and answers none: a call out is
//!   Timeout and closes only its connection, a call in line is
//!   PoolExhausted, and a new connection is Unavailable within
//!   connect_timeout; once it answers again, calls pass.
//! - redis-restart, restarted, drops every connection: the next call is
//!   ConnectionLost and clears the pool, and the call after it probes and
//!   finds the server back. Stopped, it refuses the probe, and a call next
//!   to the probe is Unavailable at once.
//! - redis-plain with `CONFIG SET timeout 1` closes the connections that
//!   idle for a second: the check of an idle connection finds it closed,
//!   and the call goes on a new one without an error.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const core = @import("core");
const redis = @import("redis");
const cmd = redis.cmd;
const e2e = @import("root.zig");

const ping = cmd.raw(void, .{"PING"});

fn within(io: Io, duration: Io.Duration) redis.OperationContext {
    return .of(core.Context.root.withDeadline(.after(Io.Clock.awake.now(io), duration)));
}

/// A client of the server at `port` with `options`, connected.
fn connectedTo(io: Io, client: *redis.Client, port: u16, buffer: []u8, options: redis.Client.Options) !void {
    var opts = options;
    opts.url = try std.fmt.bufPrint(buffer, "redis://127.0.0.1:{d}", .{port});
    client.* = try .init(testing.allocator, io, opts);
    errdefer client.deinit();
    var d: redis.Diagnostics = .{};
    client.connect(io, within(io, .fromSeconds(10)).ctx, &d) catch |err| {
        std.debug.print("connect: {t}: {s}\n", .{ err, d.message() });
        return err;
    };
}

fn awaitStats(io: Io, client: *redis.Client, comptime field: []const u8, value: usize) !void {
    const give_up: core.Deadline = .after(Io.Clock.awake.now(io), .fromSeconds(20));
    while (@field(client.stats(), field) != value) {
        if (give_up.isExpired(Io.Clock.awake.now(io))) return error.TestTimedOut;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}

/// A PING that must pass.
fn pingOk(io: Io, client: *redis.Client) !void {
    var d: redis.Diagnostics = .{};
    client.run(io, within(io, .fromSeconds(10)), ping, .{ .diagnostics = &d }) catch |err| {
        std.debug.print("ping: {t}: {s}\n", .{ err, d.message() });
        return err;
    };
}

/// Calls in the tasks of a group, which return nothing: each counts a
/// call that failed.
const Calls = struct {
    client: *redis.Client,
    failed: std.atomic.Value(u32) = .init(0),

    fn pingOnce(calls: *Calls, io: Io) void {
        calls.run(io, ping);
    }

    /// Blocks for 200 ms on a list that no one pushes to.
    fn wait(calls: *Calls, io: Io) void {
        calls.run(io, cmd.raw(void, .{ "BLPOP", "e2e:pool:nothing", "0.2" }));
    }

    fn run(calls: *Calls, io: Io, command: anytype) void {
        var d: redis.Diagnostics = .{};
        calls.client.run(io, within(io, .fromSeconds(10)), command, .{ .diagnostics = &d }) catch |err| {
            _ = calls.failed.fetchAdd(1, .acq_rel);
            std.debug.print("call: {t}: {s}\n", .{ err, d.message() });
        };
    }
};

/// 16 PINGs at once, which must all pass: the pool serves again.
fn pingsOk(io: Io, client: *redis.Client) !void {
    var calls: Calls = .{ .client = client };
    var group: Io.Group = .init;
    defer group.cancel(io);
    for (0..16) |_| try group.concurrent(io, Calls.pingOnce, .{ &calls, io });
    try group.await(io);
    try testing.expectEqual(@as(u32, 0), calls.failed.load(.acquire));
}

/// A call out while the server stalls, and how it ended.
const CallOut = struct {
    client: *redis.Client,
    result: redis.Error!void = {},
    d: redis.Diagnostics = .{},

    fn run(out: *CallOut, io: Io) void {
        out.result = out.client.run(io, within(io, .fromMilliseconds(1500)), ping, .{ .diagnostics = &out.d });
    }
};

test "a paused server: a call out is Timeout and closes only its connection, a call in line is PoolExhausted, a new connection is Unavailable within connect_timeout, and calls pass once it answers again" {
    try e2e.onZio(pausedServer);
}

fn pausedServer(io: Io) !void {
    var client: redis.Client = undefined;
    var buffer: [64]u8 = undefined;
    try connectedTo(io, &client, e2e.servers.stall_port, &buffer, .{ .url = "", .max_connections = 1, .connect_timeout = .fromMilliseconds(300) });
    defer client.deinit();
    try pingOk(io, &client);

    // The server takes what comes and answers nothing.
    try e2e.docker(&.{ "pause", e2e.servers.stall_container });
    errdefer e2e.unpause(e2e.servers.stall_container) catch {};
    var out: CallOut = .{ .client = &client };
    var flying = try io.concurrent(CallOut.run, .{ &out, io });
    defer flying.cancel(io);
    try awaitStats(io, &client, "in_use", 1);
    // The only connection is out: the deadline of a call passes in line.
    var d: redis.Diagnostics = .{};
    try testing.expectError(error.PoolExhausted, client.run(io, within(io, .fromMilliseconds(300)), ping, .{ .diagnostics = &d }));
    try testing.expectEqualStrings("the deadline passed while the call waited for a connection", d.message());
    flying.await(io);
    try testing.expectError(error.Timeout, out.result);
    try testing.expectEqualStrings("the deadline passed before the reply came", out.d.message());
    // The timeout closed its connection, and cleared nothing.
    var stats = client.stats();
    try testing.expectEqual(@as(usize, 0), stats.connections + stats.opening + stats.waiting);
    try testing.expectEqual(@as(u64, 0), stats.clears);

    // A new connection gets no answer to HELLO: Unavailable within
    // connect_timeout, and within a shorter deadline DeadlineExceeded.
    try testing.expectError(error.Unavailable, client.run(io, .of(.root), ping, .{ .diagnostics = &d }));
    var expected: [96]u8 = undefined;
    try testing.expectEqualStrings(try std.fmt.bufPrint(&expected, "127.0.0.1:{d} did not answer within connect_timeout (300 ms)", .{e2e.servers.stall_port}), d.message());
    try testing.expectEqual(@as(?redis.Diagnostics.Phase, .connect), d.phase);
    try testing.expectError(error.DeadlineExceeded, client.run(io, within(io, .fromMilliseconds(100)), ping, .{ .diagnostics = &d }));
    try testing.expectEqualStrings(try std.fmt.bufPrint(&expected, "the deadline passed while the client connected to 127.0.0.1:{d}", .{e2e.servers.stall_port}), d.message());
    stats = client.stats();
    try testing.expectEqual(@as(usize, 0), stats.connections + stats.opening);
    try testing.expectEqual(@as(u64, 0), stats.clears);

    try e2e.unpause(e2e.servers.stall_container);
    try pingOk(io, &client);
    stats = client.stats();
    try testing.expectEqual(@as(usize, 1), stats.connections);
    try testing.expectEqual(@as(u64, 0), stats.clears);
}

/// Two connections of `client`, idle: two calls that block for 200 ms at
/// once.
fn twoIdle(io: Io, client: *redis.Client) !void {
    var calls: Calls = .{ .client = client };
    var group: Io.Group = .init;
    defer group.cancel(io);
    for (0..2) |_| try group.concurrent(io, Calls.wait, .{ &calls, io });
    try group.await(io);
    try testing.expectEqual(@as(u32, 0), calls.failed.load(.acquire));
    try testing.expectEqual(@as(usize, 2), client.stats().idle);
}

/// The pool after a clear by a server that went: one clear, a new
/// generation, and no connection of the old one left.
fn expectCleared(client: *redis.Client) !void {
    const stats = client.stats();
    try testing.expectEqual(@as(u64, 1), stats.clears);
    try testing.expectEqual(@as(u64, 1), stats.generation);
    try testing.expectEqual(@as(usize, 0), stats.connections + stats.opening);
}

test "after a restart the idle connections are dead: the next call is ConnectionLost and clears the pool, the call after it probes and finds the server back, and the pool serves again" {
    try e2e.onZio(restartWithIdle);
}

fn restartWithIdle(io: Io) !void {
    var client: redis.Client = undefined;
    var buffer: [64]u8 = undefined;
    try connectedTo(io, &client, e2e.servers.restart_port, &buffer, .{ .url = "" });
    defer client.deinit();
    try twoIdle(io, &client);
    try e2e.restart(e2e.servers.restart_container);
    var d: redis.Diagnostics = .{};
    const lost = client.run(io, within(io, .fromSeconds(10)), ping, .{ .diagnostics = &d });
    if (lost) |_| {
        std.debug.print("a PING on a connection to the server before the restart went through\n", .{});
        return error.TestUnexpectedResult;
    } else |err| testing.expectEqual(error.ConnectionLost, err) catch |e| {
        std.debug.print("the first PING: {t}: {s}\n", .{ err, d.message() });
        return e;
    };
    try expectCleared(&client);
    // The pool is paused: the next call is its probe.
    try pingOk(io, &client);
    try testing.expectEqual(@as(usize, 1), client.stats().connections);
    try pingsOk(io, &client);
    try testing.expectEqual(@as(u64, 1), client.stats().clears);
}

test "a stopped server refuses the probe, and a call next to it is Unavailable at once; once the server is back, calls pass again within a few seconds" {
    try e2e.onZio(stoppedServer);
}

fn stoppedServer(io: Io) !void {
    var client: redis.Client = undefined;
    var buffer: [64]u8 = undefined;
    try connectedTo(io, &client, e2e.servers.restart_port, &buffer, .{ .url = "", .connect_timeout = .fromMilliseconds(300) });
    defer client.deinit();
    try pingOk(io, &client);

    try e2e.docker(&.{ "stop", e2e.servers.restart_container });
    var started = false;
    defer if (!started) e2e.start(e2e.servers.restart_container) catch {};
    var d: redis.Diagnostics = .{};
    // The idle connection went with the server: the pool clears.
    try testing.expectError(error.ConnectionLost, client.run(io, within(io, .fromSeconds(10)), ping, .{ .diagnostics = &d }));
    try expectCleared(&client);
    // This call is the probe, and nothing takes its connection.
    if (client.run(io, within(io, .fromSeconds(10)), ping, .{ .diagnostics = &d })) |_| {
        return error.TestUnexpectedResult;
    } else |err| if (err != error.Unavailable) {
        std.debug.print("the probe: {t}: {s}\n", .{ err, d.message() });
        return err;
    }
    // Next to it, within 500 ms: Unavailable at once, and nothing opens.
    try testing.expectError(error.Unavailable, client.run(io, within(io, .fromSeconds(10)), ping, .{ .diagnostics = &d }));
    try testing.expect(std.mem.startsWith(u8, d.message(), "the pool is paused after a clear; the next probe may open a connection in "));
    try testing.expectEqual(@as(usize, 0), client.stats().opening);

    started = true;
    try e2e.start(e2e.servers.restart_container);
    // A probe at most every 500 ms: within a few seconds one finds the
    // server, and every call before it is Unavailable.
    const give_up: core.Deadline = .after(Io.Clock.awake.now(io), .fromSeconds(5));
    while (true) {
        client.run(io, within(io, .fromSeconds(10)), ping, .{ .diagnostics = &d }) catch |err| {
            if (err != error.Unavailable or give_up.isExpired(Io.Clock.awake.now(io))) {
                std.debug.print("after the start: {t}: {s}\n", .{ err, d.message() });
                return err;
            }
            try io.sleep(.fromMilliseconds(100), .awake);
            continue;
        };
        break;
    }
    try pingsOk(io, &client);
    try testing.expectEqual(@as(u64, 1), client.stats().clears);
}

test "a connection that the server closed for its timeout while it idled: its check finds it closed, and the call goes on a new one without an error" {
    try e2e.onZio(serverTimeout);
}

/// `CONFIG SET timeout <seconds>` on the server of `client`.
fn setTimeout(io: Io, client: *redis.Client, seconds: []const u8) !void {
    var d: redis.Diagnostics = .{};
    client.run(io, within(io, .fromSeconds(10)), cmd.raw(void, .{ "CONFIG", "SET", "timeout", seconds }), .{ .diagnostics = &d }) catch |err| {
        std.debug.print("CONFIG SET timeout {s}: {t}: {s}\n", .{ seconds, err, d.message() });
        return err;
    };
}

fn clientId(io: Io, client: *redis.Client) !i64 {
    var d: redis.Diagnostics = .{};
    return client.run(io, within(io, .fromSeconds(10)), cmd.raw(i64, .{ "CLIENT", "ID" }), .{ .diagnostics = &d }) catch |err| {
        std.debug.print("CLIENT ID: {t}: {s}\n", .{ err, d.message() });
        return err;
    };
}

fn serverTimeout(io: Io) !void {
    var client: redis.Client = undefined;
    var buffer: [64]u8 = undefined;
    try connectedTo(io, &client, e2e.servers.plain_port, &buffer, .{ .url = "" });
    defer client.deinit();
    // The check after 500 ms instead of 30 s, before the first call.
    client.pool.options.idle_check = .fromMilliseconds(500);
    // The server closes the connections that idle for a second.
    try setTimeout(io, &client, "1");
    defer setTimeout(io, &client, "0") catch {};
    const before = try clientId(io, &client);
    try io.sleep(.fromMilliseconds(2500), .awake);
    const after = try clientId(io, &client);
    // Another connection answered, and nothing failed.
    try testing.expect(after != before);
    const stats = client.stats();
    try testing.expectEqual(@as(usize, 1), stats.connections);
    try testing.expectEqual(@as(u64, 0), stats.clears);
}
