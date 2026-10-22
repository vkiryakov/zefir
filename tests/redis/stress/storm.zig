//! A storm of cut connections. 100 tasks call a client through a proxy to
//! redis-plain that cuts every connection through it again and again, 120
//! times, most of them a few milliseconds apart and every tenth after a
//! pause long enough for the pool to find the server again; twice the
//! proxy first stalls for longer than the calls' deadline, so that the
//! calls out time out, and twice it refuses new connections for a while
//! after the cut, so that the probes of the paused pool fail. The tasks
//! ping, increment a counter, run a pipeline of 20 commands, run a
//! transaction after WATCH on a Conn, and wait 100 ms in BLPOP, each under
//! a deadline of 500 ms.
//!
//! Every call ends by its deadline, give or take a second, with success
//! or with an error that such a storm gives: ConnectionLost, Timeout,
//! Unavailable, PoolExhausted or DeadlineExceeded. Afterwards the client
//! serves every call again, and holds nothing of the storm: no connection
//! in use or opening, no call in line, its memory within its bound, and
//! all of it back at deinit.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const redis = @import("redis");
const cmd = redis.cmd;
const e2e = @import("e2e");
const stress = @import("root.zig");
const Proxy = @import("Proxy.zig");

const workers = 100;
const cuts = 120;
/// Every this many rounds, the storm pauses long enough for a probe of
/// the pool to find the server and for calls to go out again.
const calm_every = 10;
/// The rounds of the storm that stall the proxy before they cut, and those
/// that refuse new connections after the cut.
const stall_rounds = [_]usize{ 40, 80 };
const refuse_rounds = [_]usize{ 60, 100 };
const stall_time: Io.Duration = .fromMilliseconds(800);
const refuse_time: Io.Duration = .fromMilliseconds(600);
const max_connections = 20;
const call_deadline: Io.Duration = .fromMilliseconds(500);
/// How much later than its deadline a call may end: a task may wait for
/// its executor.
const tolerance: Io.Duration = .fromSeconds(1);
const pipeline_length = 20;
const nothing = "stress:storm:nothing";

/// How the calls of the storm ended.
const Outcomes = struct {
    ok: std.atomic.Value(u32) = .init(0),
    lost: std.atomic.Value(u32) = .init(0),
    timeout: std.atomic.Value(u32) = .init(0),
    unavailable: std.atomic.Value(u32) = .init(0),
    exhausted: std.atomic.Value(u32) = .init(0),
    deadline_exceeded: std.atomic.Value(u32) = .init(0),
    /// Any other error: a bug.
    unexpected: std.atomic.Value(u32) = .init(0),
    /// Calls that ended later than their deadline and the tolerance.
    late: std.atomic.Value(u32) = .init(0),
    /// Workers that stopped.
    done: std.atomic.Value(usize) = .init(0),

    /// Counts the end of a call; true when it failed.
    fn record(o: *Outcomes, result: anyerror!void, took: Io.Duration, d: *const redis.Diagnostics) bool {
        if (took.nanoseconds > call_deadline.nanoseconds + tolerance.nanoseconds) {
            if (o.late.fetchAdd(1, .monotonic) == 0) std.debug.print("  a call took {d} ms: {s}\n", .{ took.toMilliseconds(), d.message() });
        }
        result catch |err| {
            const counter = switch (err) {
                error.ConnectionLost => &o.lost,
                error.Timeout => &o.timeout,
                error.Unavailable => &o.unavailable,
                error.PoolExhausted => &o.exhausted,
                error.DeadlineExceeded => &o.deadline_exceeded,
                else => &o.unexpected,
            };
            const first = counter.fetchAdd(1, .monotonic) == 0;
            if (counter == &o.unexpected and first) std.debug.print("  a call: {t}: {s}\n", .{ err, d.message() });
            return true;
        };
        _ = o.ok.fetchAdd(1, .monotonic);
        return false;
    }

    fn failed(o: *const Outcomes) u32 {
        return o.lost.load(.monotonic) + o.timeout.load(.monotonic) + o.unavailable.load(.monotonic) +
            o.exhausted.load(.monotonic) + o.deadline_exceeded.load(.monotonic) + o.unexpected.load(.monotonic);
    }
};

/// A task of the storm: it calls until told to stop, a kind of call after
/// another.
const Worker = struct {
    client: *redis.Client,
    index: usize,
    outcomes: *Outcomes,
    stop: *const std.atomic.Value(bool),
    /// The counter of this worker alone, so that WATCH sees no other
    /// writer.
    key_buffer: [32]u8 = undefined,
    key: []const u8 = "",

    fn run(w: *Worker, io: Io) Io.Cancelable!void {
        defer _ = w.outcomes.done.fetchAdd(1, .acq_rel);
        var sequence: usize = 0;
        while (!w.stop.load(.acquire)) : (sequence += 1) {
            var d: redis.Diagnostics = .{};
            const began = Io.Clock.awake.now(io);
            const result = w.call(io, sequence, &d);
            const failed = w.outcomes.record(result, stress.elapsedSince(io, began), &d);
            // A paused pool refuses at once: no spinning on it.
            try io.sleep(.fromMilliseconds(if (failed) 10 else 1), .awake);
        }
    }

    fn call(w: *Worker, io: Io, sequence: usize, d: *redis.Diagnostics) !void {
        const op = stress.within(io, call_deadline);
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const options: redis.RunOptions = .{ .allocator = arena.allocator(), .diagnostics = d };
        switch ((w.index + sequence) % 5) {
            0 => try w.client.run(io, op, cmd.ping(), options),
            1 => {
                _ = try w.client.run(io, op, cmd.incr(w.key), options);
            },
            2 => {
                const commands: [pipeline_length]cmd.Incr = @splat(cmd.incr(w.key));
                const results = try w.client.pipeline(io, op, @as([]const cmd.Incr, &commands), options);
                for (results) |result| _ = try result;
            },
            3 => {
                var conn = try w.client.acquire(io, op);
                defer conn.release(io);
                try conn.run(io, op, cmd.watch(&.{w.key}), options);
                const results = try conn.transaction(io, op, .{ cmd.incr(w.key), cmd.get(i64, w.key) }, options) orelse return error.TestWatchedKeyChanged;
                const read = (try results[1]) orelse return error.TestWrongCounter;
                if (read != try results[0]) return error.TestWrongCounter;
            },
            else => if (try w.client.run(io, op, cmd.blpop([]const u8, &.{nothing}, .{ .at_most = .fromMilliseconds(100) }), options)) |_| {
                return error.TestPopped;
            },
        }
    }
};

fn storm(io: Io) !void {
    var proxy: Proxy = undefined;
    try proxy.start(testing.io, testing.allocator, e2e.servers.plain_port);
    defer proxy.stop();
    var counting: stress.CountingAllocator = .{ .child = testing.allocator };
    var buffer: [64]u8 = undefined;
    var client: redis.Client = undefined;
    try stress.connected(io, &client, &counting, .{ .url = try proxy.url(&buffer), .max_connections = max_connections, .connect_timeout = .fromMilliseconds(500) });
    {
        defer client.deinit();
        const before = counting.resetPeak();
        var outcomes: Outcomes = .{};
        var stop: std.atomic.Value(bool) = .init(false);
        var tasks: [workers]Worker = undefined;
        var group: Io.Group = .init;
        defer group.cancel(io);
        for (&tasks, 0..) |*w, i| {
            w.* = .{ .client = &client, .index = i, .outcomes = &outcomes, .stop = &stop };
            w.key = try std.fmt.bufPrint(&w.key_buffer, "stress:storm:{d}", .{i});
            try group.concurrent(io, Worker.run, .{ w, io });
        }
        var prng: std.Random.DefaultPrng = .init(0x2026_1022);
        const random = prng.random();
        for (0..cuts) |round| {
            const stalls = std.mem.findScalar(usize, &stall_rounds, round) != null;
            // Before a stall, time for a probe to find the server and for
            // the calls to fill the pool again: the stall holds calls out.
            const pause: Io.Duration = if (stalls)
                .fromSeconds(1)
            else if (round % calm_every == 0)
                .fromMilliseconds(random.intRangeAtMost(u32, 300, 700))
            else
                .fromMilliseconds(random.intRangeAtMost(u32, 2, 30));
            try io.sleep(pause, .awake);
            if (stalls) {
                proxy.stall(true);
                try io.sleep(stall_time, .awake);
            }
            _ = proxy.cutAll();
            proxy.stall(false);
            if (std.mem.findScalar(usize, &refuse_rounds, round) != null) {
                proxy.refuse(true);
                try io.sleep(refuse_time, .awake);
                proxy.refuse(false);
            }
        }
        stop.store(true, .release);
        try stress.awaitCount(io, &outcomes.done, workers, .fromSeconds(10));
        try group.await(io);

        // The pool may be paused after the last cut: a call probes it at
        // most every 500 ms, and finds the server through the proxy.
        try recover(io, &client);
        try pingsAtOnce(io, &client);
        const stats = client.stats();
        const peak = counting.peak.load(.monotonic) -| before;
        const held = counting.current.load(.monotonic) -| before;
        const held_bound = max_connections * stress.bytes_per_connection;
        // The pool's connections and two being opened.
        const peak_bound = (max_connections + 2) * stress.bytes_per_connection;
        std.debug.print("  {d} cuts, {d} connections cut; {d} calls ok, {d} failed: ConnectionLost {d}, Timeout {d}, Unavailable {d}, PoolExhausted {d}, DeadlineExceeded {d}, other {d}\n", .{ cuts, proxy.cuts, outcomes.ok.load(.monotonic), outcomes.failed(), outcomes.lost.load(.monotonic), outcomes.timeout.load(.monotonic), outcomes.unavailable.load(.monotonic), outcomes.exhausted.load(.monotonic), outcomes.deadline_exceeded.load(.monotonic), outcomes.unexpected.load(.monotonic) });
        std.debug.print("  {d} clears; client heap: peak {d} KiB (bound {d} KiB), {d} KiB held after (bound {d} KiB); process max RSS {?d} MiB\n", .{ stats.clears, peak / 1024, peak_bound / 1024, held / 1024, held_bound / 1024, stress.maxRssMiB() });
        try testing.expectEqual(@as(u32, 0), outcomes.unexpected.load(.monotonic));
        try testing.expectEqual(@as(u32, 0), outcomes.late.load(.monotonic));
        try testing.expect(outcomes.ok.load(.monotonic) > 0);
        try testing.expect(proxy.cuts > 0);
        // The cuts ended calls out, and the stalls outlasted calls out.
        try testing.expect(outcomes.lost.load(.monotonic) > 0);
        try testing.expect(outcomes.timeout.load(.monotonic) > 0);
        // A cut of a call out clears the pool, and each clear begins a
        // generation.
        try testing.expect(stats.clears > 0);
        try testing.expectEqual(stats.clears, stats.generation);
        try stress.expectAtRest(stats);
        try testing.expect(peak <= peak_bound);
        try testing.expect(held <= held_bound);
        var keys: [workers][]const u8 = undefined;
        for (&keys, &tasks) |*key, *w| key.* = w.key;
        var d: redis.Diagnostics = .{};
        _ = try client.run(io, stress.within(io, .fromSeconds(10)), cmd.del(&keys), .{ .diagnostics = &d });
    }
    // deinit gave back all the client held.
    try testing.expectEqual(@as(usize, 0), counting.current.load(.monotonic));
}

/// Pings until a ping succeeds, for 10 s at most.
fn recover(io: Io, client: *redis.Client) !void {
    const began = Io.Clock.awake.now(io);
    while (true) {
        var d: redis.Diagnostics = .{};
        if (client.run(io, stress.within(io, .fromSeconds(2)), cmd.ping(), .{ .diagnostics = &d })) |_| {
            return;
        } else |err| if (stress.elapsedSince(io, began).toSeconds() >= 10) {
            std.debug.print("  no ping went through 10 s after the storm: {t}: {s}\n", .{ err, d.message() });
            return err;
        }
        try io.sleep(.fromMilliseconds(100), .awake);
    }
}

/// 100 pings at once, which must all succeed: the pool serves again.
fn pingsAtOnce(io: Io, client: *redis.Client) !void {
    const Pings = struct {
        failed: std.atomic.Value(u32) = .init(0),

        fn one(p: *@This(), c: *redis.Client, io_: Io) Io.Cancelable!void {
            var d: redis.Diagnostics = .{};
            c.run(io_, stress.within(io_, .fromSeconds(10)), cmd.ping(), .{ .diagnostics = &d }) catch |err| {
                if (p.failed.fetchAdd(1, .monotonic) == 0) std.debug.print("  a ping after the storm: {t}: {s}\n", .{ err, d.message() });
            };
        }
    };
    var pings: Pings = .{};
    var group: Io.Group = .init;
    defer group.cancel(io);
    for (0..100) |_| try group.concurrent(io, Pings.one, .{ &pings, client, io });
    try group.await(io);
    try testing.expectEqual(@as(u32, 0), pings.failed.load(.monotonic));
}

test "a storm of 120 cuts, stalls and refusals through a proxy: every call ends by its deadline with success or an error a storm gives, and afterwards the client serves again and holds nothing of it" {
    try stress.onZio(storm);
}
