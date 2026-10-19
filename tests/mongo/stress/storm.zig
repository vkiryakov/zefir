//! A storm of cut connections. 100 tasks call a client through a proxy to
//! mongo-plain that cuts every connection through it again and again, 30
//! times, 50 to 400 ms apart; twice it first stalls for longer than the
//! calls' deadline, so that the calls out time out, and twice it refuses
//! new connections for a while after the cut, so that the probes of the
//! paused pool fail. The tasks ping, insert, read a document, and read a
//! collection through a cursor, each under a deadline of 500 ms.
//!
//! Every call ends by its deadline, give or take a second, with success
//! or with an error that such a storm gives: ConnectionLost, Timeout,
//! Unavailable, PoolExhausted or DeadlineExceeded. Afterwards the client
//! serves every call again, and holds nothing of the storm: no connection
//! in use or opening, no call in line, no cursor open, its memory within
//! its bound, and all of it back at deinit.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const core = @import("core");
const mongo = @import("mongo");
const bson = mongo.bson;
const e2e = @import("e2e");
const stress = @import("root.zig");
const Proxy = @import("Proxy.zig");

const workers = 100;
const cuts = 30;
/// The rounds of the storm that stall the proxy before they cut, and those
/// that refuse new connections after the cut.
const stall_rounds = [_]usize{ 10, 20 };
const refuse_rounds = [_]usize{ 15, 25 };
const stall_time: Io.Duration = .fromMilliseconds(800);
const refuse_time: Io.Duration = .fromMilliseconds(600);
const max_pool_size = 20;
const call_deadline: Io.Duration = .fromMilliseconds(500);
/// How much later than its deadline a call may end: the deinit of a
/// cursor sends killCursors within cursor_close_timeout, and a task may
/// wait for its executor.
const tolerance: Io.Duration = .fromSeconds(1);
const cursor_close_timeout: Io.Duration = .fromMilliseconds(200);
const cursor_docs = 200;
const cursor_batch = 20;
/// What a cursor holds of the client's memory: its state, its namespace and
/// the reply of its batch, with a margin.
const bytes_per_cursor = 64 * 1024;

const ping: mongo.Command = .{ .database = "admin", .body = bson.literal(.{ .ping = 1 }) };

fn within(io: Io, duration: Io.Duration) mongo.OperationContext {
    return .of(core.Context.root.withDeadline(.after(Io.Clock.awake.now(io), duration)));
}

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
    fn record(o: *Outcomes, result: anyerror!void, took: Io.Duration, d: *const mongo.Diagnostics) bool {
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
    db: mongo.Database,
    index: usize,
    outcomes: *Outcomes,
    stop: *const std.atomic.Value(bool),

    fn run(w: *Worker, io: Io) Io.Cancelable!void {
        defer _ = w.outcomes.done.fetchAdd(1, .acq_rel);
        var sequence: usize = 0;
        while (!w.stop.load(.acquire)) : (sequence += 1) {
            var d: mongo.Diagnostics = .{};
            const began = Io.Clock.awake.now(io);
            const result = w.call(io, sequence, &d);
            const failed = w.outcomes.record(result, stress.elapsedSince(io, began), &d);
            // A paused pool refuses at once: no spinning on it.
            try io.sleep(.fromMilliseconds(if (failed) 10 else 1), .awake);
        }
    }

    fn call(w: *Worker, io: Io, sequence: usize, d: *mongo.Diagnostics) !void {
        const op = within(io, call_deadline);
        const kind: u2 = @truncate(w.index + sequence);
        switch (kind) {
            0 => {
                const pong = try w.db.client.runCommand(io, op, ping, .{ .allocator = testing.allocator, .diagnostics = d });
                pong.deinit();
            },
            1 => {
                // An _id of its own each time: an insert that may have run
                // is not made again.
                const id: i64 = @intCast(w.index * 1_000_000 + sequence);
                var inserted = try w.db.collection("storm").insertOne(io, op, .{ ._id = id }, .{ .allocator = testing.allocator, .diagnostics = d });
                inserted.deinit(testing.allocator);
            },
            2 => {
                const id: i64 = @intCast(sequence % cursor_docs);
                const found = (try w.db.collection("storm_cursor").findOne(io, op, .{ ._id = id }, .{ .allocator = testing.allocator, .diagnostics = d })) orelse return error.TestNotFound;
                found.deinit();
            },
            3 => {
                const cursor = try w.db.collection("storm_cursor").find(io, op, .{}, .{ .allocator = testing.allocator, .batch_size = cursor_batch, .diagnostics = d });
                defer cursor.deinit(io);
                var count: usize = 0;
                while (try cursor.next(io, op)) |_| count += 1;
                if (count != cursor_docs) return error.TestWrongCount;
            },
        }
    }
};

fn storm(io: Io) !void {
    var proxy: Proxy = undefined;
    try proxy.start(testing.io, testing.allocator, e2e.servers.plain_port);
    defer proxy.stop();
    var counting: stress.CountingAllocator = .{ .child = testing.allocator };
    var buffer: [192]u8 = undefined;
    const uri = try proxy.uri(&buffer, std.fmt.comptimePrint("appName=zefir-stress-storm&maxPoolSize={d}&connectTimeoutMS=500&serverSelectionTimeoutMS=1000", .{max_pool_size}));
    var client: mongo.Client = try .init(counting.allocator(), io, .{ .uri = uri, .cursor_close_timeout = cursor_close_timeout });
    {
        defer client.deinit();
        var d: mongo.Diagnostics = .{};
        client.connect(io, within(io, .fromSeconds(10)).ctx, &d) catch |err| {
            std.debug.print("  connect: {t}: {s}\n", .{ err, d.message() });
            return err;
        };
        var ids: bson.ObjectId.Generator = .init(io);
        const db: mongo.Database = .init(&client, "zefir_stress", &ids);
        try db.drop(io, within(io, .fromSeconds(10)), .{ .allocator = testing.allocator });
        defer db.drop(io, within(io, .fromSeconds(10)), .{ .allocator = testing.allocator }) catch {};
        try fill(io, db);

        const before = counting.resetPeak();
        var outcomes: Outcomes = .{};
        var stop: std.atomic.Value(bool) = .init(false);
        var tasks: [workers]Worker = undefined;
        var group: Io.Group = .init;
        defer group.cancel(io);
        for (&tasks, 0..) |*w, i| {
            w.* = .{ .db = db, .index = i, .outcomes = &outcomes, .stop = &stop };
            try group.concurrent(io, Worker.run, .{ w, io });
        }
        var prng: std.Random.DefaultPrng = .init(0x2026_1019);
        const random = prng.random();
        for (0..cuts) |round| {
            const stalls = std.mem.findScalar(usize, &stall_rounds, round) != null;
            // Before a stall, time for a probe to find the server and for
            // the calls to fill the pool again: the stall holds calls out.
            const pause: Io.Duration = if (stalls) .fromSeconds(1) else .fromMilliseconds(random.intRangeAtMost(u32, 50, 400));
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
        const held_bound = max_pool_size * stress.bytes_per_connection;
        // The pool's connections, two being opened, and a cursor of each
        // task.
        const peak_bound = (max_pool_size + 2) * stress.bytes_per_connection + workers * bytes_per_cursor;
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
        try testing.expectEqual(stats.connections, stats.idle);
        try testing.expectEqual(@as(usize, 0), stats.in_use + stats.opening + stats.waiting + stats.open_cursors);
        try testing.expect(peak <= peak_bound);
        try testing.expect(held <= held_bound);
    }
    // deinit gave back all the client held.
    try testing.expectEqual(@as(usize, 0), counting.current.load(.monotonic));
}

/// The collection that the tasks read: `cursor_docs` documents.
fn fill(io: Io, db: mongo.Database) !void {
    const Doc = struct { _id: i64 };
    var docs: [cursor_docs]Doc = undefined;
    for (&docs, 0..) |*doc, i| doc.* = .{ ._id = @intCast(i) };
    var result = try db.collection("storm_cursor").insertMany(io, within(io, .fromSeconds(10)), @as([]const Doc, &docs), .{ .allocator = testing.allocator });
    defer result.deinit(testing.allocator);
    try testing.expectEqual(@as(u64, cursor_docs), result.inserted);
}

/// Pings until a ping succeeds, for 10 s at most.
fn recover(io: Io, client: *mongo.Client) !void {
    const began = Io.Clock.awake.now(io);
    while (true) {
        var d: mongo.Diagnostics = .{};
        if (client.runCommand(io, within(io, .fromSeconds(2)), ping, .{ .allocator = testing.allocator, .diagnostics = &d })) |reply| {
            reply.deinit();
            return;
        } else |err| if (stress.elapsedSince(io, began).toSeconds() >= 10) {
            std.debug.print("  no ping went through 10 s after the storm: {t}: {s}\n", .{ err, d.message() });
            return err;
        }
        try io.sleep(.fromMilliseconds(100), .awake);
    }
}

/// 100 pings at once, which must all succeed: the pool serves again.
fn pingsAtOnce(io: Io, client: *mongo.Client) !void {
    const Pings = struct {
        failed: std.atomic.Value(u32) = .init(0),

        fn one(p: *@This(), c: *mongo.Client, io_: Io) Io.Cancelable!void {
            var d: mongo.Diagnostics = .{};
            const reply = c.runCommand(io_, within(io_, .fromSeconds(10)), ping, .{ .allocator = testing.allocator, .diagnostics = &d }) catch |err| {
                if (p.failed.fetchAdd(1, .monotonic) == 0) std.debug.print("  a ping after the storm: {t}: {s}\n", .{ err, d.message() });
                return;
            };
            reply.deinit();
        }
    };
    var pings: Pings = .{};
    var group: Io.Group = .init;
    defer group.cancel(io);
    for (0..100) |_| try group.concurrent(io, Pings.one, .{ &pings, client, io });
    try group.await(io);
    try testing.expectEqual(@as(u32, 0), pings.failed.load(.monotonic));
}

test "a storm of 30 cuts, stalls and refusals through a proxy: every call ends by its deadline with success or an error a storm gives, and afterwards the client serves again and holds nothing of it" {
    try stress.onZio(storm);
}
