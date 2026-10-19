//! Tests of `engine/Pool.zig` on fake connections, as the CMAP
//! specification allows: what the pool does with its line of calls, its
//! budgets, its openings and its generations, without a server. Every test
//! runs under a time limit of 5 s.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const core = @import("core");
const mongo = @import("../root.zig");
const Diagnostics = mongo.Diagnostics;
const Pool = @import("../engine/Pool.zig");
const connect = @import("../engine/connect.zig");
const time = @import("../engine/time.zig");
const early_io = @import("../testing/early_io.zig");
const within5s = @import("connection_tests.zig").within5s;

/// A connection that is nothing but its entry in the pool.
const FakeConn = struct {
    pooled: Pool.Entry = .{ .hooks = &hooks },
    fakes: *Fakes,
    id: u32,
    cut: std.atomic.Value(bool) = .init(false),

    const hooks: Pool.Entry.Hooks = .{ .destroy = destroy, .cut = cutIt };

    fn of(entry: *Pool.Entry) *FakeConn {
        return @alignCast(@fieldParentPtr("pooled", entry));
    }

    fn destroy(entry: *Pool.Entry) void {
        const conn = of(entry);
        _ = conn.fakes.destroyed.fetchAdd(1, .acq_rel);
        testing.allocator.destroy(conn);
    }

    fn cutIt(entry: *Pool.Entry, io: Io) void {
        _ = io;
        of(entry).cut.store(true, .release);
    }
};

/// Opens fake connections: at once, or held until `release`, or failing
/// with `fail_with`. Opening is a cancelation point, as on a socket.
const Fakes = struct {
    hold: std.atomic.Value(bool) = .init(false),
    released: Io.Event = .unset,
    fail_with: ?mongo.Error = null,
    started: std.atomic.Value(u32) = .init(0),
    opened: std.atomic.Value(u32) = .init(0),
    destroyed: std.atomic.Value(u32) = .init(0),

    fn opener(f: *Fakes) Pool.Opener {
        return .{ .context = f, .open = open };
    }

    fn open(context: *anyopaque, io: Io, limits: Pool.Limits, attempt: *connect.Attempt, d: ?*Diagnostics) mongo.Error!*Pool.Entry {
        _ = limits;
        const f: *Fakes = @ptrCast(@alignCast(context));
        _ = f.started.fetchAdd(1, .acq_rel);
        while (f.hold.load(.acquire) and !f.released.isSet()) {
            if (attempt.isStopped(io)) return fail(d, error.Closed, "the client was closed while it connected");
            f.released.waitTimeout(io, .{ .duration = .{ .raw = .fromMilliseconds(1), .clock = .awake } }) catch |err| switch (err) {
                error.Timeout => {},
                error.Canceled => {
                    io.recancel();
                    return fail(d, error.Cancelled, "the task was canceled while it connected");
                },
            };
        }
        if (f.fail_with) |err| return fail(d, err, "the fake refuses");
        const conn = try testing.allocator.create(FakeConn);
        conn.* = .{ .fakes = f, .id = f.opened.fetchAdd(1, .acq_rel) + 1 };
        return &conn.pooled;
    }

    fn release(f: *Fakes, io: Io) void {
        f.released.set(io);
    }
};

fn fail(d: ?*Diagnostics, err: mongo.Error, message: []const u8) mongo.Error {
    if (d) |x| x.set(.connect, null, "{s}", .{message});
    return err;
}

fn options(max_size: u32) Pool.Options {
    return .{ .server = .{ .host = "fake", .port = 1 }, .max_size = max_size };
}

/// A budget of `ms` from now, for the deadline and the checkout alike.
fn within(io: Io, ms: i64) Pool.Limits {
    const deadline: core.Deadline = .after(time.now(io), .fromMilliseconds(ms));
    return .{ .deadline = deadline, .checkout = deadline };
}

/// A pool that `connect` made ready, with its first connection idle.
fn ready(io: Io, pool: *Pool, fakes: *Fakes, opts: Pool.Options) !void {
    pool.* = .init(opts);
    try pool.enter(io, null);
    defer pool.leave(io);
    try pool.connect(io, fakes.opener(), within(io, 5000), null);
}

/// Waits until `count` calls wait in line.
fn awaitWaiting(io: Io, pool: *Pool, count: usize) !void {
    const give_up: core.Deadline = .after(time.now(io), .fromSeconds(4));
    while (pool.counts(io).waiting != count) {
        if (time.expired(io, give_up)) return error.TestTimedOut;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}

fn closeAndDeinit(io: Io, pool: *Pool) void {
    pool.close(io, .zero);
    pool.deinit();
}

test "connect opens the first connection and leaves it idle; calls take the idle one, and open one when none is idle" {
    try within5s(testing.io, takeAndOpen, .{testing.io});
}

fn takeAndOpen(io: Io) !void {
    var fakes: Fakes = .{};
    var pool: Pool = undefined;
    try ready(io, &pool, &fakes, options(4));
    defer closeAndDeinit(io, &pool);
    try testing.expectEqual(Pool.Counts{ .idle = 1, .in_use = 0, .opening = 0, .waiting = 0, .generation = 0, .clears = 0 }, pool.counts(io));
    const first = try pool.checkOut(io, fakes.opener(), within(io, 1000), null);
    try testing.expectEqual(@as(u32, 1), FakeConn.of(first).id);
    // None idle: the second call opens one.
    const second = try pool.checkOut(io, fakes.opener(), within(io, 1000), null);
    try testing.expectEqual(@as(u32, 2), FakeConn.of(second).id);
    try testing.expectEqual(@as(usize, 2), pool.counts(io).in_use);
    pool.checkIn(io, first, .ok);
    pool.checkIn(io, second, .ok);
    try testing.expectEqual(@as(usize, 2), pool.counts(io).idle);
    // The connection checked in last is taken first.
    const again = try pool.checkOut(io, fakes.opener(), within(io, 1000), null);
    try testing.expectEqual(@as(u32, 2), FakeConn.of(again).id);
    pool.checkIn(io, again, .ok);
    try testing.expectEqual(@as(u32, 2), fakes.opened.load(.acquire));
}

test "before connect a call is Unavailable, and after close it is Closed" {
    const io = testing.io;
    var fakes: Fakes = .{};
    var pool: Pool = .init(options(4));
    var d: Diagnostics = .{};
    try pool.enter(io, &d);
    try testing.expectError(error.Unavailable, pool.checkOut(io, fakes.opener(), within(io, 1000), &d));
    try testing.expectEqualStrings("connect() has not succeeded", d.message());
    try testing.expectEqual(Diagnostics.Phase.checkout, d.phase.?);
    pool.leave(io);
    pool.close(io, .zero);
    try testing.expectError(error.Closed, pool.enter(io, &d));
    try testing.expectEqualStrings("the client is closed", d.message());
    pool.deinit();
    try testing.expectEqual(@as(u32, 0), fakes.started.load(.acquire));
}

/// One call in line: it takes a connection, writes its number down while
/// it holds it, and gives it back.
const Line = struct {
    pool: *Pool,
    fakes: *Fakes,
    mutex: Io.Mutex = .init,
    served: [8]u8 = undefined,
    count: usize = 0,
    failures: std.atomic.Value(u32) = .init(0),

    fn call(l: *Line, io: Io, number: u8) void {
        const entry = l.pool.checkOut(io, l.fakes.opener(), within(io, 4000), null) catch {
            _ = l.failures.fetchAdd(1, .acq_rel);
            return;
        };
        l.mutex.lockUncancelable(io);
        l.served[l.count] = number;
        l.count += 1;
        l.mutex.unlock(io);
        l.pool.checkIn(io, entry, .ok);
    }
};

test "calls that find no connection wait in line and are served first come first served" {
    try within5s(testing.io, firstComeFirstServed, .{testing.io});
}

fn firstComeFirstServed(io: Io) !void {
    var fakes: Fakes = .{};
    var pool: Pool = undefined;
    try ready(io, &pool, &fakes, options(1));
    defer closeAndDeinit(io, &pool);
    const held = try pool.checkOut(io, fakes.opener(), within(io, 1000), null);
    var line: Line = .{ .pool = &pool, .fakes = &fakes };
    var group: Io.Group = .init;
    defer group.cancel(io);
    // Each call joins the line once the one before it waits.
    for (0..8) |i| {
        try group.concurrent(io, Line.call, .{ &line, io, @as(u8, @intCast(i)) });
        try awaitWaiting(io, &pool, i + 1);
    }
    pool.checkIn(io, held, .ok);
    try group.await(io);
    try testing.expectEqual(@as(u32, 0), line.failures.load(.acquire));
    try testing.expectEqualSlices(u8, &.{ 0, 1, 2, 3, 4, 5, 6, 7 }, line.served[0..line.count]);
    // One connection served them all: maxPoolSize is 1.
    try testing.expectEqual(@as(u32, 1), fakes.opened.load(.acquire));
    try testing.expectEqual(Pool.Counts{ .idle = 1, .in_use = 0, .opening = 0, .waiting = 0, .generation = 0, .clears = 0 }, pool.counts(io));
}

fn checkOutFails(io: Io, pool: *Pool, fakes: *Fakes, limits: Pool.Limits, expected: mongo.Error, message: []const u8) !void {
    var d: Diagnostics = .{};
    try testing.expectError(expected, pool.checkOut(io, fakes.opener(), limits, &d));
    try testing.expectEqualStrings(message, d.message());
    try testing.expectEqual(Diagnostics.Phase.checkout, d.phase.?);
}

fn checkOutAndIn(io: Io, pool: *Pool, fakes: *Fakes) !void {
    const entry = try pool.checkOut(io, fakes.opener(), within(io, 4000), null);
    pool.checkIn(io, entry, .ok);
}

test "a call whose budget ends in line is PoolExhausted, and the call behind it still gets its turn" {
    try within5s(testing.io, budgetInLine, .{testing.io});
}

fn budgetInLine(io: Io) !void {
    var fakes: Fakes = .{};
    var pool: Pool = undefined;
    try ready(io, &pool, &fakes, options(1));
    defer closeAndDeinit(io, &pool);
    const held = try pool.checkOut(io, fakes.opener(), within(io, 1000), null);
    // The deadline of the call ends first.
    var short = try io.concurrent(checkOutFails, .{ io, &pool, &fakes, within(io, 60), error.PoolExhausted, "the deadline passed while the call waited for a connection" });
    try awaitWaiting(io, &pool, 1);
    var behind = try io.concurrent(checkOutAndIn, .{ io, &pool, &fakes });
    try awaitWaiting(io, &pool, 2);
    try short.await(io);
    try awaitWaiting(io, &pool, 1);
    pool.checkIn(io, held, .ok);
    try behind.await(io);
    // serverSelectionTimeoutMS ends first.
    const again = try pool.checkOut(io, fakes.opener(), within(io, 1000), null);
    defer pool.checkIn(io, again, .ok);
    const selection: Pool.Limits = .{ .deadline = .after(time.now(io), .fromSeconds(4)), .checkout = .after(time.now(io), .fromMilliseconds(30)) };
    try checkOutFails(io, &pool, &fakes, selection, error.PoolExhausted, "serverSelectionTimeoutMS passed while the call waited for a connection");
    try testing.expectEqual(@as(usize, 0), pool.counts(io).waiting);
}

test "a call whose task is canceled in line is Cancelled and stays canceled, and the call behind it gets its turn" {
    try within5s(testing.io, canceledInLine, .{testing.io});
}

fn waitAndBeCanceled(io: Io, pool: *Pool, fakes: *Fakes) !void {
    try checkOutFails(io, pool, fakes, within(io, 4000), error.Cancelled, "the task was canceled while it waited for a connection");
    try testing.expectError(error.Canceled, io.sleep(.fromSeconds(5), .awake));
}

fn canceledInLine(io: Io) !void {
    var fakes: Fakes = .{};
    var pool: Pool = undefined;
    try ready(io, &pool, &fakes, options(1));
    defer closeAndDeinit(io, &pool);
    const held = try pool.checkOut(io, fakes.opener(), within(io, 1000), null);
    var first = try io.concurrent(waitAndBeCanceled, .{ io, &pool, &fakes });
    try awaitWaiting(io, &pool, 1);
    var behind = try io.concurrent(checkOutAndIn, .{ io, &pool, &fakes });
    try awaitWaiting(io, &pool, 2);
    try first.cancel(io);
    try awaitWaiting(io, &pool, 1);
    pool.checkIn(io, held, .ok);
    try behind.await(io);
    try testing.expectEqual(@as(usize, 0), pool.counts(io).waiting);
    try testing.expectEqual(@as(usize, 1), pool.counts(io).idle);
}

test "at most maxConnecting connections open at once, and each goes to the call that opened it" {
    try within5s(testing.io, maxConnecting, .{testing.io});
}

fn openAndKeep(io: Io, pool: *Pool, fakes: *Fakes, out: **Pool.Entry) !void {
    out.* = try pool.checkOut(io, fakes.opener(), within(io, 4000), null);
}

fn awaitStarted(io: Io, fakes: *Fakes, count: u32) !void {
    const give_up: core.Deadline = .after(time.now(io), .fromSeconds(4));
    while (fakes.started.load(.acquire) != count) {
        if (time.expired(io, give_up)) return error.TestTimedOut;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}

fn maxConnecting(io: Io) !void {
    var fakes: Fakes = .{};
    var pool: Pool = undefined;
    try ready(io, &pool, &fakes, options(10));
    defer closeAndDeinit(io, &pool);
    const held = try pool.checkOut(io, fakes.opener(), within(io, 1000), null);
    fakes.hold.store(true, .release);
    var entries: [3]*Pool.Entry = undefined;
    var a = try io.concurrent(openAndKeep, .{ io, &pool, &fakes, &entries[0] });
    var b = try io.concurrent(openAndKeep, .{ io, &pool, &fakes, &entries[1] });
    try awaitStarted(io, &fakes, 3);
    // Two openings at once: the third call waits in line.
    var c = try io.concurrent(openAndKeep, .{ io, &pool, &fakes, &entries[2] });
    try awaitWaiting(io, &pool, 1);
    try testing.expectEqual(@as(usize, 2), pool.counts(io).opening);
    try testing.expectEqual(@as(u32, 3), fakes.started.load(.acquire));
    // A connection checked in goes to the call in line, not to the
    // openings, which keep theirs.
    pool.checkIn(io, held, .ok);
    try c.await(io);
    try testing.expectEqual(@as(u32, 1), FakeConn.of(entries[2]).id);
    fakes.release(io);
    try a.await(io);
    try b.await(io);
    try testing.expect(FakeConn.of(entries[0]).id != 1 and FakeConn.of(entries[1]).id != 1);
    for (entries) |entry| pool.checkIn(io, entry, .ok);
    try testing.expectEqual(Pool.Counts{ .idle = 3, .in_use = 0, .opening = 0, .waiting = 0, .generation = 0, .clears = 0 }, pool.counts(io));
}

test "a canceled opening frees its place for the call behind it" {
    try within5s(testing.io, canceledOpening, .{testing.io});
}

fn openAndBeCanceled(io: Io, pool: *Pool, fakes: *Fakes) !void {
    var d: Diagnostics = .{};
    try testing.expectError(error.Cancelled, pool.checkOut(io, fakes.opener(), within(io, 4000), &d));
    try testing.expectError(error.Canceled, io.sleep(.fromSeconds(5), .awake));
}

fn canceledOpening(io: Io) !void {
    var fakes: Fakes = .{};
    var pool: Pool = undefined;
    try ready(io, &pool, &fakes, options(1));
    defer closeAndDeinit(io, &pool);
    // A broken connection closes at check-in, and leaves its place free.
    const broken = try pool.checkOut(io, fakes.opener(), within(io, 1000), null);
    pool.checkIn(io, broken, .broken);
    try testing.expectEqual(@as(u32, 1), fakes.destroyed.load(.acquire));
    fakes.hold.store(true, .release);
    var opening = try io.concurrent(openAndBeCanceled, .{ io, &pool, &fakes });
    try awaitStarted(io, &fakes, 2);
    // maxPoolSize is 1, and the opening holds the place.
    var behind = try io.concurrent(checkOutAndIn, .{ io, &pool, &fakes });
    try awaitWaiting(io, &pool, 1);
    try opening.cancel(io);
    // The call in line opens in the place the canceled one left.
    fakes.hold.store(false, .release);
    try behind.await(io);
    try testing.expectEqual(Pool.Counts{ .idle = 1, .in_use = 0, .opening = 0, .waiting = 0, .generation = 0, .clears = 0 }, pool.counts(io));
}

test "a failed opening gives its error to the call and frees its place" {
    try within5s(testing.io, failedOpening, .{testing.io});
}

fn failedOpening(io: Io) !void {
    var fakes: Fakes = .{};
    var pool: Pool = undefined;
    try ready(io, &pool, &fakes, options(2));
    defer closeAndDeinit(io, &pool);
    const taken = try pool.checkOut(io, fakes.opener(), within(io, 1000), null);
    fakes.fail_with = error.Unavailable;
    var d: Diagnostics = .{};
    try testing.expectError(error.Unavailable, pool.checkOut(io, fakes.opener(), within(io, 1000), &d));
    try testing.expectEqualStrings("the fake refuses", d.message());
    try testing.expectEqual(Pool.Counts{ .idle = 0, .in_use = 1, .opening = 0, .waiting = 0, .generation = 0, .clears = 0 }, pool.counts(io));
    fakes.fail_with = null;
    const second = try pool.checkOut(io, fakes.opener(), within(io, 1000), null);
    pool.checkIn(io, second, .ok);
    pool.checkIn(io, taken, .ok);
    try testing.expectEqual(@as(usize, 2), pool.counts(io).idle);
}

test "an idle connection past maxIdleTimeMS closes at check-out, and a broken one at check-in, also where a sleep ends early" {
    // The sleeps of std's Io on Windows may end a tick of its timer early.
    for ([_]Io{ testing.io, early_io.io() }) |io| try within5s(testing.io, perished, .{io});
}

fn perished(io: Io) !void {
    var fakes: Fakes = .{};
    var pool: Pool = undefined;
    var opts = options(4);
    opts.max_idle_time = .fromMilliseconds(30);
    try ready(io, &pool, &fakes, opts);
    defer closeAndDeinit(io, &pool);
    try time.sleepUntil(io, .after(time.now(io), .fromMilliseconds(40)));
    const fresh = try pool.checkOut(io, fakes.opener(), within(io, 1000), null);
    try testing.expectEqual(@as(u32, 2), FakeConn.of(fresh).id);
    try testing.expectEqual(@as(u32, 1), fakes.destroyed.load(.acquire));
    pool.checkIn(io, fresh, .broken);
    try testing.expectEqual(@as(u32, 2), fakes.destroyed.load(.acquire));
    try testing.expectEqual(@as(usize, 0), pool.counts(io).idle);
}

test "a clear closes the idle connections at once and those in use at check-in, and pauses the pool" {
    try within5s(testing.io, clearCloses, .{testing.io});
}

fn clearCloses(io: Io) !void {
    var fakes: Fakes = .{};
    var pool: Pool = undefined;
    try ready(io, &pool, &fakes, options(3));
    defer closeAndDeinit(io, &pool);
    const a = try pool.checkOut(io, fakes.opener(), within(io, 1000), null);
    const b = try pool.checkOut(io, fakes.opener(), within(io, 1000), null);
    const c = try pool.checkOut(io, fakes.opener(), within(io, 1000), null);
    pool.checkIn(io, c, .ok);
    pool.checkIn(io, a, .{ .clear = "the connection to fake:1 broke" });
    try testing.expectEqual(@as(u32, 2), fakes.destroyed.load(.acquire));
    try testing.expectEqual(Pool.Counts{ .idle = 0, .in_use = 1, .opening = 0, .waiting = 0, .generation = 1, .clears = 1 }, pool.counts(io));
    // b is of the generation before: it closes when it comes back.
    pool.checkIn(io, b, .ok);
    try testing.expectEqual(@as(u32, 3), fakes.destroyed.load(.acquire));
    try testing.expectEqual(@as(usize, 0), pool.counts(io).idle);
}

test "the calls in line at a clear get Unavailable" {
    try within5s(testing.io, clearSendsAway, .{testing.io});
}

fn clearSendsAway(io: Io) !void {
    var fakes: Fakes = .{};
    var pool: Pool = undefined;
    try ready(io, &pool, &fakes, options(1));
    defer closeAndDeinit(io, &pool);
    const held = try pool.checkOut(io, fakes.opener(), within(io, 1000), null);
    var first = try io.concurrent(checkOutFails, .{ io, &pool, &fakes, within(io, 4000), error.Unavailable, "the pool was cleared while the call waited for a connection" });
    try awaitWaiting(io, &pool, 1);
    var second = try io.concurrent(checkOutFails, .{ io, &pool, &fakes, within(io, 4000), error.Unavailable, "the pool was cleared while the call waited for a connection" });
    try awaitWaiting(io, &pool, 2);
    pool.checkIn(io, held, .{ .clear = "the server at fake:1 is shutting down" });
    try first.await(io);
    try second.await(io);
    try testing.expectEqual(@as(usize, 0), pool.counts(io).waiting);
}

/// A pool that `ready` made, then cleared.
fn cleared(io: Io, pool: *Pool, fakes: *Fakes, opts: Pool.Options) !void {
    try ready(io, pool, fakes, opts);
    const entry = try pool.checkOut(io, fakes.opener(), within(io, 1000), null);
    pool.checkIn(io, entry, .{ .clear = "the connection to fake:1 broke" });
}

test "a paused pool lets the first call open a connection as a probe and turns the others away at once; a probe that succeeds makes it ready" {
    try within5s(testing.io, probeSucceeds, .{testing.io});
}

fn probeSucceeds(io: Io) !void {
    var fakes: Fakes = .{};
    var pool: Pool = undefined;
    try cleared(io, &pool, &fakes, options(2));
    defer closeAndDeinit(io, &pool);
    fakes.hold.store(true, .release);
    var probe: *Pool.Entry = undefined;
    var probing = try io.concurrent(openAndKeep, .{ io, &pool, &fakes, &probe });
    try awaitStarted(io, &fakes, 2);
    try checkOutFails(io, &pool, &fakes, within(io, 1000), error.Unavailable, "the pool is paused after a clear, and a probe is opening a connection");
    fakes.release(io);
    try probing.await(io);
    // Ready again: the next call opens a connection of its own.
    const next = try pool.checkOut(io, fakes.opener(), within(io, 1000), null);
    pool.checkIn(io, next, .ok);
    pool.checkIn(io, probe, .ok);
    try testing.expectEqual(Pool.Counts{ .idle = 2, .in_use = 0, .opening = 0, .waiting = 0, .generation = 1, .clears = 1 }, pool.counts(io));
}

test "a probe that fails leaves the pool paused, and the next probe goes 500 ms after it at the soonest" {
    try within5s(testing.io, probeFails, .{testing.io});
}

fn probeFails(io: Io) !void {
    var fakes: Fakes = .{};
    var pool: Pool = undefined;
    try cleared(io, &pool, &fakes, options(2));
    defer closeAndDeinit(io, &pool);
    fakes.fail_with = error.Unavailable;
    const start = time.now(io);
    var d: Diagnostics = .{};
    try testing.expectError(error.Unavailable, pool.checkOut(io, fakes.opener(), within(io, 1000), &d));
    try testing.expectEqualStrings("the fake refuses", d.message());
    fakes.fail_with = null;
    try testing.expectError(error.Unavailable, pool.checkOut(io, fakes.opener(), within(io, 1000), &d));
    try testing.expect(std.mem.startsWith(u8, d.message(), "the pool is paused after a clear; the next probe may open a connection in "));
    try testing.expectEqual(@as(u32, 2), fakes.started.load(.acquire));
    try time.sleepUntil(io, .after(start, Pool.probe_interval));
    const conn = try pool.checkOut(io, fakes.opener(), within(io, 1000), null);
    pool.checkIn(io, conn, .ok);
    try testing.expectEqual(Pool.Counts{ .idle = 1, .in_use = 0, .opening = 0, .waiting = 0, .generation = 1, .clears = 1 }, pool.counts(io));
}

test "a failed authentication clears the pool; an error of an older generation, a broken connection and another failed opening do not" {
    try within5s(testing.io, whatClears, .{testing.io});
}

fn whatClears(io: Io) !void {
    var fakes: Fakes = .{};
    var pool: Pool = undefined;
    try ready(io, &pool, &fakes, options(3));
    defer closeAndDeinit(io, &pool);
    const old = try pool.checkOut(io, fakes.opener(), within(io, 1000), null);
    const gone = try pool.checkOut(io, fakes.opener(), within(io, 1000), null);
    pool.checkIn(io, gone, .{ .clear = "the connection to fake:1 broke" });
    const probe = try pool.checkOut(io, fakes.opener(), within(io, 1000), null);
    // The error of a connection from before the clear is stale.
    pool.checkIn(io, old, .{ .clear = "the connection to fake:1 broke" });
    // A timeout closes its own connection only.
    pool.checkIn(io, probe, .broken);
    fakes.fail_with = error.Unavailable;
    try testing.expectError(error.Unavailable, pool.checkOut(io, fakes.opener(), within(io, 1000), null));
    try testing.expectEqual(Pool.Counts{ .idle = 0, .in_use = 0, .opening = 0, .waiting = 0, .generation = 1, .clears = 1 }, pool.counts(io));
    fakes.fail_with = error.AuthenticationFailed;
    try testing.expectError(error.AuthenticationFailed, pool.checkOut(io, fakes.opener(), within(io, 1000), null));
    try testing.expectEqual(@as(u64, 2), pool.counts(io).generation);
    try testing.expectEqual(@as(u64, 2), pool.counts(io).clears);
    // Paused again, within 500 ms of the probe before.
    fakes.fail_with = null;
    var d: Diagnostics = .{};
    try testing.expectError(error.Unavailable, pool.checkOut(io, fakes.opener(), within(io, 1000), &d));
    try testing.expect(std.mem.startsWith(u8, d.message(), "the pool is paused after a clear; the next probe may open a connection in "));
}

test "a failed authentication of connect leaves the pool as it was: it was not ready" {
    const io = testing.io;
    var fakes: Fakes = .{ .fail_with = error.AuthenticationFailed };
    var pool: Pool = .init(options(2));
    defer closeAndDeinit(io, &pool);
    try testing.expectError(error.AuthenticationFailed, pool.connect(io, fakes.opener(), within(io, 1000), null));
    try testing.expectEqual(@as(u64, 0), pool.counts(io).clears);
    fakes.fail_with = null;
    try pool.connect(io, fakes.opener(), within(io, 1000), null);
    try testing.expect(pool.isConnected(io));
}
