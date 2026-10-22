//! Closing a client while 1,000 calls are in flight, in three rounds, each
//! on a fresh client of redis-plain:
//!
//! - cut: 1,000 calls wait in BLPOP on as many connections, and `close`
//!   cuts them all at close_timeout: each ends with ConnectionLost;
//! - drain: on a pool of 32, the 32 calls on connections, in a BLPOP of
//!   two seconds, end well within close_timeout, and the 968 waiting in
//!   line get Closed at once;
//! - cut again, as the first.
//!
//! In each, `close` returns in time, every call returns right after it,
//! no connection is left, and all of the client's memory comes back at
//! deinit.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const redis = @import("redis");
const cmd = redis.cmd;
const e2e = @import("e2e");
const stress = @import("root.zig");

/// A list that nothing pushes to: BLPOP on it waits its whole timeout.
const nothing = "stress:close:nothing";

fn waitFor(comptime seconds: u32) cmd.Blpop([]const u8) {
    return cmd.blpop([]const u8, &.{nothing}, .{ .at_most = .fromSeconds(seconds) });
}

/// Calls that run in tasks of a group: each counts what it got against
/// what it expected.
const Calls = struct {
    c: *redis.Client,
    /// Null: success, BLPOP's null or PONG.
    expected: ?redis.Error = null,
    message: []const u8 = "",
    done: std.atomic.Value(usize) = .init(0),
    unexpected: std.atomic.Value(u32) = .init(0),

    fn blpop(calls: *Calls, io: Io, command: cmd.Blpop([]const u8)) Io.Cancelable!void {
        defer _ = calls.done.fetchAdd(1, .acq_rel);
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        var d: redis.Diagnostics = .{};
        const result = calls.c.run(io, stress.within(io, .fromSeconds(60)), command, .{ .allocator = arena.allocator(), .diagnostics = &d });
        if (result) |popped| {
            if (popped == null) return calls.check(null, &d);
            calls.wrong("  a BLPOP got an element of a list that nothing pushes to\n");
        } else |err| calls.check(err, &d);
    }

    fn ping(calls: *Calls, io: Io) Io.Cancelable!void {
        defer _ = calls.done.fetchAdd(1, .acq_rel);
        var d: redis.Diagnostics = .{};
        if (calls.c.run(io, stress.within(io, .fromSeconds(60)), cmd.ping(), .{ .diagnostics = &d })) |_| {
            calls.check(null, &d);
        } else |err| calls.check(err, &d);
    }

    /// Counts the end of a call, null for success, against what it
    /// expected.
    fn check(calls: *Calls, got: ?anyerror, d: *const redis.Diagnostics) void {
        if (got) |err| {
            if (calls.expected) |expected| {
                if (err == expected and std.mem.eql(u8, calls.message, d.message())) return;
            }
            if (calls.unexpected.fetchAdd(1, .monotonic) == 0) std.debug.print("  a call: {t}: {s}\n", .{ err, d.message() });
        } else if (calls.expected != null) {
            if (calls.unexpected.fetchAdd(1, .monotonic) == 0) std.debug.print("  a call: ok, and an error was expected\n", .{});
        }
    }

    fn wrong(calls: *Calls, comptime text: []const u8) void {
        if (calls.unexpected.fetchAdd(1, .monotonic) == 0) std.debug.print(text, .{});
    }
};

fn clientOf(io: Io, client: *redis.Client, counting: *stress.CountingAllocator, buffer: []u8, max_connections: u32, close_timeout: Io.Duration) !void {
    const url = try std.fmt.bufPrint(buffer, "redis://127.0.0.1:{d}", .{e2e.servers.plain_port});
    try stress.connected(io, client, counting, .{ .url = url, .max_connections = max_connections, .close_timeout = close_timeout });
}

const close_cut_timeout: Io.Duration = .fromMilliseconds(300);

/// 1,000 calls on as many connections, cut by `close` at close_timeout.
fn cutRound(io: Io) !void {
    var counting: stress.CountingAllocator = .{ .child = testing.allocator };
    var client: redis.Client = undefined;
    var buffer: [64]u8 = undefined;
    try clientOf(io, &client, &counting, &buffer, 1000, close_cut_timeout);
    {
        defer client.deinit();
        var out: Calls = .{ .c = &client, .expected = error.ConnectionLost, .message = "close() of the client cut the exchange" };
        var group: Io.Group = .init;
        defer group.cancel(io);
        for (0..1000) |_| try group.concurrent(io, Calls.blpop, .{ &out, io, waitFor(10) });
        // The pool opens two connections at a time.
        try stress.awaitStats(io, &client, "in_use", 1000, .fromSeconds(60));
        const stopping = Io.Clock.awake.now(io);
        client.close(io);
        const took = stress.elapsedSince(io, stopping);
        // Every call has left the client once close returns, and returns
        // right after.
        try stress.awaitCount(io, &out.done, 1000, .fromSeconds(1));
        try group.await(io);
        std.debug.print("  cut: close ended 1,000 calls on 1,000 connections in {d} ms (close_timeout {d} ms); client heap at most {d} KiB\n", .{ took.toMilliseconds(), close_cut_timeout.toMilliseconds(), counting.peak.load(.monotonic) / 1024 });
        try testing.expectEqual(@as(u32, 0), out.unexpected.load(.monotonic));
        try testing.expect(took.nanoseconds >= close_cut_timeout.nanoseconds);
        try testing.expect(took.toMilliseconds() < close_cut_timeout.toMilliseconds() + 2000);
        const stats = client.stats();
        try testing.expectEqual(@as(usize, 0), stats.connections + stats.opening + stats.waiting);
    }
    try testing.expectEqual(@as(usize, 0), counting.current.load(.monotonic));
}

/// 32 calls on a pool of 32 that end within close_timeout, and 968 in
/// line.
fn drainRound(io: Io) !void {
    var counting: stress.CountingAllocator = .{ .child = testing.allocator };
    var client: redis.Client = undefined;
    var buffer: [64]u8 = undefined;
    try clientOf(io, &client, &counting, &buffer, 32, .fromSeconds(5));
    {
        defer client.deinit();
        var out: Calls = .{ .c = &client };
        var flying: Io.Group = .init;
        defer flying.cancel(io);
        for (0..32) |_| try flying.concurrent(io, Calls.blpop, .{ &out, io, waitFor(2) });
        try stress.awaitStats(io, &client, "in_use", 32, .fromSeconds(30));
        var in_line: Calls = .{ .c = &client, .expected = error.Closed, .message = "the client was closed while the call waited for a connection" };
        var waiting: Io.Group = .init;
        defer waiting.cancel(io);
        for (0..968) |_| try waiting.concurrent(io, Calls.ping, .{ &in_line, io });
        try stress.awaitStats(io, &client, "waiting", 968, .fromSeconds(30));
        const stopping = Io.Clock.awake.now(io);
        client.close(io);
        const took = stress.elapsedSince(io, stopping);
        try stress.awaitCount(io, &out.done, 32, .fromSeconds(1));
        try stress.awaitCount(io, &in_line.done, 968, .fromSeconds(1));
        try flying.await(io);
        try waiting.await(io);
        std.debug.print("  drain: close let 32 calls end and sent 968 in line away in {d} ms; client heap at most {d} KiB\n", .{ took.toMilliseconds(), counting.peak.load(.monotonic) / 1024 });
        try testing.expectEqual(@as(u32, 0), out.unexpected.load(.monotonic));
        try testing.expectEqual(@as(u32, 0), in_line.unexpected.load(.monotonic));
        // The calls out waited two seconds in BLPOP, which a server at hz
        // 10 ends up to 100 ms late, and close waited for them.
        try testing.expect(took.toMilliseconds() < 2000 + 1500);
        const stats = client.stats();
        try testing.expectEqual(@as(usize, 0), stats.connections + stats.opening + stats.waiting);
    }
    try testing.expectEqual(@as(usize, 0), counting.current.load(.monotonic));
}

fn rounds(io: Io) !void {
    try cutRound(io);
    try drainRound(io);
    try cutRound(io);
}

test "close with 1,000 calls in flight, three rounds: it cuts 1,000 calls on as many connections at close_timeout; it lets 32 calls end and sends 968 in line away; and again the first" {
    try stress.onZio(rounds);
}
