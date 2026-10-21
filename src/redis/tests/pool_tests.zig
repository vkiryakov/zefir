//! Tests of `engine/Pool.zig` on fake connections: what the pool does with
//! its line of calls, their deadlines, its openings, its generations and
//! its probes, without a server. Every test runs under a time limit of
//! 5 s.
//!
//! A test that fails with a connection still out leaves the pool as it
//! is: the testing allocator reports the connection as a leak, where the
//! assertions of `Pool.deinit` would panic.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const core = @import("core");
const errors = @import("../errors.zig");
const Error = errors.Error;
const Diagnostics = errors.Diagnostics;
const Pool = @import("../engine/Pool.zig");
const Attempt = @import("../engine/connect.zig").Attempt;
const time = @import("../engine/time.zig");
const within5s = @import("time_limit.zig").within5s;

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
        free(of(entry));
    }

    fn free(conn: *FakeConn) void {
        _ = conn.fakes.destroyed.fetchAdd(1, .acq_rel);
        testing.allocator.destroy(conn);
    }

    fn cutIt(entry: *Pool.Entry, io: Io) void {
        _ = io;
        const conn = of(entry);
        conn.cut.store(true, .release);
        _ = conn.fakes.cuts.fetchAdd(1, .acq_rel);
    }
};

/// Opens fake connections: at once, or held until `release`, or failing
/// with `fail_with`. Each opening makes its connection first, as a socket
/// before its handshake, and frees it when it does not finish. Opening is
/// a cancelation point, as on a socket.
const Fakes = struct {
    hold: std.atomic.Value(bool) = .init(false),
    released: Io.Event = .unset,
    fail_with: ?Error = null,
    started: std.atomic.Value(u32) = .init(0),
    made: std.atomic.Value(u32) = .init(0),
    destroyed: std.atomic.Value(u32) = .init(0),
    cuts: std.atomic.Value(u32) = .init(0),

    fn opener(f: *Fakes) Pool.Opener {
        return .{ .context = f, .open = open };
    }

    fn open(context: *anyopaque, io: Io, deadline: ?core.Deadline, attempt: *Attempt, d: ?*Diagnostics) Error!*Pool.Entry {
        _ = deadline;
        const f: *Fakes = @ptrCast(@alignCast(context));
        _ = f.started.fetchAdd(1, .acq_rel);
        const conn = testing.allocator.create(FakeConn) catch return error.OutOfMemory;
        conn.* = .{ .fakes = f, .id = f.made.fetchAdd(1, .acq_rel) + 1 };
        while (f.hold.load(.acquire) and !f.released.isSet()) {
            if (attempt.isStopped(io)) {
                FakeConn.free(conn);
                return fail(d, error.Closed, "the client was closed while it connected");
            }
            f.released.waitTimeout(io, .{ .duration = .{ .raw = .fromMilliseconds(1), .clock = .awake } }) catch |err| switch (err) {
                error.Timeout => {},
                error.Canceled => {
                    FakeConn.free(conn);
                    io.recancel();
                    return fail(d, error.Cancelled, "the task was canceled while it connected");
                },
            };
        }
        if (f.fail_with) |err| {
            FakeConn.free(conn);
            return fail(d, err, "the fake refuses");
        }
        return &conn.pooled;
    }

    fn release(f: *Fakes, io: Io) void {
        f.released.set(io);
    }
};

fn fail(d: ?*Diagnostics, err: Error, message: []const u8) Error {
    if (d) |x| x.set(.connect, null, "{s}", .{message});
    return err;
}

fn options(max_size: u32) Pool.Options {
    return .{ .server = .{ .host = "fake", .port = 1 }, .max_size = max_size };
}

/// A deadline `ms` from now.
fn within(io: Io, ms: i64) ?core.Deadline {
    return core.Deadline.after(time.now(io), .fromMilliseconds(ms));
}

/// A pool that `connect` made ready, with its first connection idle.
fn ready(io: Io, pool: *Pool, fakes: *Fakes, opts: Pool.Options) !void {
    pool.* = .init(opts);
    try pool.enter(io, null);
    defer pool.leave(io);
    try pool.connect(io, fakes.opener(), within(io, 5000), null);
}

/// Closes the pool and frees it, unless a test failed with a connection
/// out or a call in: see the top of the file.
fn closeAndDeinit(io: Io, pool: *Pool) void {
    if (pool.counts(io).in_use != 0 or pool.calls != 0) return;
    pool.close(io, .zero);
    pool.deinit();
}

/// Frees a pool that its test closed, unless the test failed before.
fn deinitClosed(pool: *Pool) void {
    if (pool.state != .closed or pool.in_use_count != 0 or pool.opening_count != 0 or pool.calls != 0) return;
    pool.deinit();
}

/// Waits until `count` calls wait in line.
fn awaitWaiting(io: Io, pool: *Pool, count: usize) !void {
    const give_up: core.Deadline = .after(time.now(io), .fromSeconds(4));
    while (pool.counts(io).waiting != count) {
        if (time.expired(io, give_up)) return error.TestTimedOut;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}

fn awaitStarted(io: Io, fakes: *Fakes, count: u32) !void {
    const give_up: core.Deadline = .after(time.now(io), .fromSeconds(4));
    while (fakes.started.load(.acquire) != count) {
        if (time.expired(io, give_up)) return error.TestTimedOut;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}

fn awaitState(io: Io, pool: *Pool, state: Pool.State) !void {
    const give_up: core.Deadline = .after(time.now(io), .fromSeconds(4));
    while (true) {
        pool.mutex.lockUncancelable(io);
        const now = pool.state;
        pool.mutex.unlock(io);
        if (now == state) return;
        if (time.expired(io, give_up)) return error.TestTimedOut;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}

/// The clears of these tests log warnings, which the default runner
/// prints: they stay out of a passing run.
fn quiet() std.log.Level {
    const level = testing.log_level;
    testing.log_level = .err;
    return level;
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
    // The connection checked in last is taken first; without a deadline
    // too.
    const again = try pool.checkOut(io, fakes.opener(), null, null);
    try testing.expectEqual(@as(u32, 2), FakeConn.of(again).id);
    pool.checkIn(io, again, .ok);
    try testing.expectEqual(@as(u32, 2), fakes.made.load(.acquire));
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
    served: [5]u8 = undefined,
    count: usize = 0,
    failures: std.atomic.Value(u32) = .init(0),

    fn call(l: *Line, io: Io, number: u8) void {
        // No deadline: the call waits as long as it takes.
        const entry = l.pool.checkOut(io, l.fakes.opener(), null, null) catch {
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

test "five calls that find no connection wait in line and are served first come first served" {
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
    var back = false;
    defer if (!back) pool.checkIn(io, held, .ok);
    // Each call joins the line once the one before it waits.
    for (0..5) |i| {
        try group.concurrent(io, Line.call, .{ &line, io, @as(u8, @intCast(i)) });
        try awaitWaiting(io, &pool, i + 1);
    }
    back = true;
    pool.checkIn(io, held, .ok);
    try group.await(io);
    try testing.expectEqual(@as(u32, 0), line.failures.load(.acquire));
    try testing.expectEqualSlices(u8, &.{ 0, 1, 2, 3, 4 }, line.served[0..line.count]);
    // One connection served them all: the pool holds one.
    try testing.expectEqual(@as(u32, 1), fakes.made.load(.acquire));
    try testing.expectEqual(Pool.Counts{ .idle = 1, .in_use = 0, .opening = 0, .waiting = 0, .generation = 0, .clears = 0 }, pool.counts(io));
}

fn checkOutFails(io: Io, pool: *Pool, fakes: *Fakes, deadline: ?core.Deadline, expected: Error, message: []const u8) !void {
    var d: Diagnostics = .{};
    const result = pool.checkOut(io, fakes.opener(), deadline, &d);
    if (result) |entry| {
        pool.checkIn(io, entry, .ok);
        return error.TestUnexpectedResult;
    } else |err| try testing.expectEqual(expected, err);
    try testing.expectEqualStrings(message, d.message());
    try testing.expectEqual(Diagnostics.Phase.checkout, d.phase.?);
}

fn checkOutAndIn(io: Io, pool: *Pool, fakes: *Fakes) !void {
    const entry = try pool.checkOut(io, fakes.opener(), within(io, 4000), null);
    pool.checkIn(io, entry, .ok);
}

test "a call whose deadline ends in line is PoolExhausted, and the call behind it moves up and gets its turn" {
    try within5s(testing.io, deadlineInLine, .{testing.io});
}

fn deadlineInLine(io: Io) !void {
    var fakes: Fakes = .{};
    var pool: Pool = undefined;
    try ready(io, &pool, &fakes, options(1));
    defer closeAndDeinit(io, &pool);
    const held = try pool.checkOut(io, fakes.opener(), within(io, 1000), null);
    var back = false;
    defer if (!back) pool.checkIn(io, held, .ok);
    const short = within(io, 60).?;
    var first = try io.concurrent(checkOutFails, .{ io, &pool, &fakes, short, error.PoolExhausted, "the deadline passed while the call waited for a connection" });
    defer first.cancel(io) catch {};
    try awaitWaiting(io, &pool, 1);
    var behind = try io.concurrent(checkOutAndIn, .{ io, &pool, &fakes });
    defer behind.cancel(io) catch {};
    try awaitWaiting(io, &pool, 2);
    try first.await(io);
    try testing.expect(time.expired(io, short));
    // The call behind it is first in line now.
    try awaitWaiting(io, &pool, 1);
    back = true;
    pool.checkIn(io, held, .ok);
    try behind.await(io);
    try testing.expectEqual(Pool.Counts{ .idle = 1, .in_use = 0, .opening = 0, .waiting = 0, .generation = 0, .clears = 0 }, pool.counts(io));
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
    var back = false;
    defer if (!back) pool.checkIn(io, held, .ok);
    var first = try io.concurrent(waitAndBeCanceled, .{ io, &pool, &fakes });
    defer first.cancel(io) catch {};
    try awaitWaiting(io, &pool, 1);
    var behind = try io.concurrent(checkOutAndIn, .{ io, &pool, &fakes });
    defer behind.cancel(io) catch {};
    try awaitWaiting(io, &pool, 2);
    try first.cancel(io);
    try awaitWaiting(io, &pool, 1);
    back = true;
    pool.checkIn(io, held, .ok);
    try behind.await(io);
    try testing.expectEqual(@as(usize, 0), pool.counts(io).waiting);
    try testing.expectEqual(@as(usize, 1), pool.counts(io).idle);
}

test "close sends the calls in line away with Closed" {
    try within5s(testing.io, closeSendsAway, .{testing.io});
}

fn closeSendsAway(io: Io) !void {
    var fakes: Fakes = .{};
    var pool: Pool = undefined;
    try ready(io, &pool, &fakes, options(1));
    defer deinitClosed(&pool);
    const held = try pool.checkOut(io, fakes.opener(), within(io, 1000), null);
    defer pool.checkIn(io, held, .ok);
    const message = "the client was closed while the call waited for a connection";
    var first = try io.concurrent(checkOutFails, .{ io, &pool, &fakes, null, error.Closed, message });
    defer first.cancel(io) catch {};
    try awaitWaiting(io, &pool, 1);
    var second = try io.concurrent(checkOutFails, .{ io, &pool, &fakes, within(io, 4000), error.Closed, message });
    defer second.cancel(io) catch {};
    try awaitWaiting(io, &pool, 2);
    // No call is in: close does not wait for the connection out.
    pool.close(io, .zero);
    try first.await(io);
    try second.await(io);
    try testing.expectEqual(Pool.State.closed, pool.state);
}

test "close gives the exchanges in progress its time, then cuts them, and returns once their calls have left" {
    try within5s(testing.io, closeCuts, .{testing.io});
}

/// A call in the pool on `entry` whose exchange ends once it is cut, as a
/// read that the cut ends: it gives the connection back, broken, and
/// leaves.
fn backWhenCut(io: Io, pool: *Pool, entry: *Pool.Entry) !void {
    defer {
        pool.checkIn(io, entry, .broken);
        pool.leave(io);
    }
    const give_up: core.Deadline = .after(time.now(io), .fromSeconds(4));
    while (!FakeConn.of(entry).cut.load(.acquire)) {
        if (time.expired(io, give_up)) return error.TestTimedOut;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}

fn closeCuts(io: Io) !void {
    var fakes: Fakes = .{};
    var pool: Pool = undefined;
    try ready(io, &pool, &fakes, options(2));
    defer deinitClosed(&pool);
    // A second connection, idle when close begins.
    const spare = try pool.checkOut(io, fakes.opener(), within(io, 1000), null);
    try pool.enter(io, null);
    const entry = pool.checkOut(io, fakes.opener(), within(io, 1000), null) catch |err| {
        pool.leave(io);
        pool.checkIn(io, spare, .ok);
        return err;
    };
    pool.checkIn(io, spare, .ok);
    var call = try io.concurrent(backWhenCut, .{ io, &pool, entry });
    defer call.cancel(io) catch {};
    const start = time.now(io);
    pool.close(io, .fromMilliseconds(50));
    const took = start.durationTo(time.now(io));
    try call.await(io);
    try testing.expect(took.nanoseconds >= Io.Duration.fromMilliseconds(50).nanoseconds);
    try testing.expect(took.toMilliseconds() < 1000);
    try testing.expectEqual(@as(u32, 1), fakes.cuts.load(.acquire));
    // The idle connection closed last; the cut one at check-in.
    try testing.expectEqual(@as(u32, 2), fakes.destroyed.load(.acquire));
    try testing.expectEqual(Pool.State.closed, pool.state);
}

test "at most two connections open at once, and each goes to the call that opened it" {
    try within5s(testing.io, maxConnecting, .{testing.io});
}

fn openAndKeep(io: Io, pool: *Pool, fakes: *Fakes, out: **Pool.Entry) !void {
    out.* = try pool.checkOut(io, fakes.opener(), within(io, 4000), null);
}

fn maxConnecting(io: Io) !void {
    var fakes: Fakes = .{};
    var pool: Pool = undefined;
    try ready(io, &pool, &fakes, options(10));
    defer closeAndDeinit(io, &pool);
    const held = try pool.checkOut(io, fakes.opener(), within(io, 1000), null);
    var back = false;
    defer if (!back) pool.checkIn(io, held, .ok);
    // Released in any case, so that no opening outlives the test.
    defer fakes.release(io);
    fakes.hold.store(true, .release);
    var entries: [3]*Pool.Entry = undefined;
    var a = try io.concurrent(openAndKeep, .{ io, &pool, &fakes, &entries[0] });
    defer a.cancel(io) catch {};
    var b = try io.concurrent(openAndKeep, .{ io, &pool, &fakes, &entries[1] });
    defer b.cancel(io) catch {};
    try awaitStarted(io, &fakes, 3);
    // Two openings at once: the third call waits in line.
    var c = try io.concurrent(openAndKeep, .{ io, &pool, &fakes, &entries[2] });
    defer c.cancel(io) catch {};
    try awaitWaiting(io, &pool, 1);
    try testing.expectEqual(@as(usize, 2), pool.counts(io).opening);
    try testing.expectEqual(@as(u32, 3), fakes.started.load(.acquire));
    // A connection checked in goes to the call in line, not to the
    // openings, which keep theirs.
    back = true;
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

test "a canceled opening closes its half-made connection and frees its place for the call behind it" {
    try within5s(testing.io, canceledOpening, .{testing.io});
}

fn openAndBeCanceled(io: Io, pool: *Pool, fakes: *Fakes) !void {
    var d: Diagnostics = .{};
    try testing.expectError(error.Cancelled, pool.checkOut(io, fakes.opener(), within(io, 4000), &d));
    try testing.expectEqualStrings("the task was canceled while it connected", d.message());
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
    defer opening.cancel(io) catch {};
    try awaitStarted(io, &fakes, 2);
    try testing.expectEqual(@as(usize, 1), pool.counts(io).opening);
    // The pool holds one, and the opening holds the place.
    var behind = try io.concurrent(checkOutAndIn, .{ io, &pool, &fakes });
    defer behind.cancel(io) catch {};
    try awaitWaiting(io, &pool, 1);
    try opening.cancel(io);
    // The half-made connection closed.
    try testing.expectEqual(@as(u32, 2), fakes.destroyed.load(.acquire));
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
    defer pool.checkIn(io, taken, .ok);
    fakes.fail_with = error.Unavailable;
    var d: Diagnostics = .{};
    try testing.expectError(error.Unavailable, pool.checkOut(io, fakes.opener(), within(io, 1000), &d));
    try testing.expectEqualStrings("the fake refuses", d.message());
    try testing.expectEqual(Pool.Counts{ .idle = 0, .in_use = 1, .opening = 0, .waiting = 0, .generation = 0, .clears = 0 }, pool.counts(io));
    fakes.fail_with = null;
    const second = try pool.checkOut(io, fakes.opener(), within(io, 1000), null);
    pool.checkIn(io, second, .ok);
    try testing.expectEqual(@as(usize, 1), pool.counts(io).idle);
}

test "a clear closes the idle connections at once and those of the generation before at check-in, and pauses the pool" {
    try within5s(testing.io, clearCloses, .{testing.io});
}

fn clearCloses(io: Io) !void {
    const level = quiet();
    defer testing.log_level = level;
    var fakes: Fakes = .{};
    var pool: Pool = undefined;
    try ready(io, &pool, &fakes, options(3));
    defer closeAndDeinit(io, &pool);
    const a = try pool.checkOut(io, fakes.opener(), within(io, 1000), null);
    const b = try pool.checkOut(io, fakes.opener(), within(io, 1000), null);
    var b_back = false;
    defer if (!b_back) pool.checkIn(io, b, .ok);
    const c = try pool.checkOut(io, fakes.opener(), within(io, 1000), null);
    pool.checkIn(io, c, .ok);
    pool.checkIn(io, a, .{ .clear = "a connection to it broke" });
    try testing.expectEqual(@as(u32, 2), fakes.destroyed.load(.acquire));
    try testing.expectEqual(Pool.Counts{ .idle = 0, .in_use = 1, .opening = 0, .waiting = 0, .generation = 1, .clears = 1 }, pool.counts(io));
    try testing.expectEqual(Pool.State.paused, pool.state);
    // b is of the generation before: it closes when it comes back.
    b_back = true;
    pool.checkIn(io, b, .ok);
    try testing.expectEqual(@as(u32, 3), fakes.destroyed.load(.acquire));
    try testing.expectEqual(@as(usize, 0), pool.counts(io).idle);
}

test "the calls in line at a clear get Unavailable" {
    try within5s(testing.io, clearSendsAway, .{testing.io});
}

fn clearSendsAway(io: Io) !void {
    const level = quiet();
    defer testing.log_level = level;
    var fakes: Fakes = .{};
    var pool: Pool = undefined;
    try ready(io, &pool, &fakes, options(1));
    defer closeAndDeinit(io, &pool);
    const held = try pool.checkOut(io, fakes.opener(), within(io, 1000), null);
    var back = false;
    defer if (!back) pool.checkIn(io, held, .ok);
    const message = "the pool was cleared while the call waited for a connection";
    var first = try io.concurrent(checkOutFails, .{ io, &pool, &fakes, within(io, 4000), error.Unavailable, message });
    defer first.cancel(io) catch {};
    try awaitWaiting(io, &pool, 1);
    var second = try io.concurrent(checkOutFails, .{ io, &pool, &fakes, null, error.Unavailable, message });
    defer second.cancel(io) catch {};
    try awaitWaiting(io, &pool, 2);
    back = true;
    pool.checkIn(io, held, .{ .clear = "a connection to it broke" });
    try first.await(io);
    try second.await(io);
    try testing.expectEqual(@as(usize, 0), pool.counts(io).waiting);
}

/// A pool that `ready` made, then cleared.
fn cleared(io: Io, pool: *Pool, fakes: *Fakes, opts: Pool.Options) !void {
    try ready(io, pool, fakes, opts);
    const entry = try pool.checkOut(io, fakes.opener(), within(io, 1000), null);
    pool.checkIn(io, entry, .{ .clear = "a connection to it broke" });
}

test "a paused pool lets the first call open a connection as a probe and turns the others away at once; a probe that succeeds makes it ready" {
    try within5s(testing.io, probeSucceeds, .{testing.io});
}

fn probeSucceeds(io: Io) !void {
    const level = quiet();
    defer testing.log_level = level;
    var fakes: Fakes = .{};
    var pool: Pool = undefined;
    try cleared(io, &pool, &fakes, options(2));
    defer closeAndDeinit(io, &pool);
    defer fakes.release(io);
    fakes.hold.store(true, .release);
    var probe: *Pool.Entry = undefined;
    var probing = try io.concurrent(openAndKeep, .{ io, &pool, &fakes, &probe });
    defer probing.cancel(io) catch {};
    try awaitStarted(io, &fakes, 2);
    try checkOutFails(io, &pool, &fakes, within(io, 1000), error.Unavailable, "the pool is paused after a clear, and a probe is opening a connection");
    try testing.expectEqual(@as(u32, 2), fakes.started.load(.acquire));
    fakes.release(io);
    try probing.await(io);
    pool.checkIn(io, probe, .ok);
    try testing.expectEqual(Pool.State.ready, pool.state);
    // Ready again: a call gets the probe's connection, and the next one
    // opens one of its own.
    const next = try pool.checkOut(io, fakes.opener(), within(io, 1000), null);
    const other = try pool.checkOut(io, fakes.opener(), within(io, 1000), null);
    pool.checkIn(io, next, .ok);
    pool.checkIn(io, other, .ok);
    try testing.expectEqual(Pool.Counts{ .idle = 2, .in_use = 0, .opening = 0, .waiting = 0, .generation = 1, .clears = 1 }, pool.counts(io));
}

test "a probe that fails leaves the pool paused, and a second probe within 500 ms is Unavailable and opens nothing" {
    try within5s(testing.io, probeFails, .{testing.io});
}

fn probeFails(io: Io) !void {
    const level = quiet();
    defer testing.log_level = level;
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
    // The second call opened nothing.
    try testing.expectEqual(@as(u32, 2), fakes.started.load(.acquire));
    try testing.expectEqual(Pool.State.paused, pool.state);
    try time.sleepUntil(io, .after(start, Pool.probe_interval));
    const conn = try pool.checkOut(io, fakes.opener(), within(io, 1000), null);
    pool.checkIn(io, conn, .ok);
    try testing.expectEqual(Pool.Counts{ .idle = 1, .in_use = 0, .opening = 0, .waiting = 0, .generation = 1, .clears = 1 }, pool.counts(io));
}

test "a server that refuses the user clears the pool; an error of an older generation, a broken connection and another failed opening do not" {
    try within5s(testing.io, whatClears, .{testing.io});
}

fn whatClears(io: Io) !void {
    const level = quiet();
    defer testing.log_level = level;
    var fakes: Fakes = .{};
    var pool: Pool = undefined;
    try ready(io, &pool, &fakes, options(3));
    defer closeAndDeinit(io, &pool);
    const old = try pool.checkOut(io, fakes.opener(), within(io, 1000), null);
    const gone = try pool.checkOut(io, fakes.opener(), within(io, 1000), null);
    pool.checkIn(io, gone, .{ .clear = "a connection to it broke" });
    const probe = try pool.checkOut(io, fakes.opener(), within(io, 1000), null);
    // The error of a connection from before the clear is stale.
    pool.checkIn(io, old, .{ .clear = "a connection to it broke" });
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

test "a refused user at connect leaves the pool as it was: it was not ready" {
    const io = testing.io;
    var fakes: Fakes = .{ .fail_with = error.AuthenticationFailed };
    var pool: Pool = .init(options(2));
    defer closeAndDeinit(io, &pool);
    try testing.expectError(error.AuthenticationFailed, pool.connect(io, fakes.opener(), within(io, 1000), null));
    try testing.expectEqual(@as(u64, 0), pool.counts(io).clears);
    try testing.expect(!pool.isConnected(io));
    fakes.fail_with = null;
    try pool.connect(io, fakes.opener(), within(io, 1000), null);
    try testing.expect(pool.isConnected(io));
}

test "a second close returns once the first is done, and one after it at once" {
    try within5s(testing.io, closeTwice, .{testing.io});
}

fn closeTwice(io: Io) !void {
    var fakes: Fakes = .{};
    var pool: Pool = undefined;
    try ready(io, &pool, &fakes, options(2));
    defer deinitClosed(&pool);
    try pool.enter(io, null);
    const entry = pool.checkOut(io, fakes.opener(), within(io, 1000), null) catch |err| {
        pool.leave(io);
        return err;
    };
    var first = try io.concurrent(Pool.close, .{ &pool, io, Io.Duration.fromSeconds(3) });
    defer first.cancel(io);
    // Runs before the cancel above: the first close ends once the call
    // has left.
    var back = false;
    defer if (!back) {
        pool.checkIn(io, entry, .ok);
        pool.leave(io);
    };
    try awaitState(io, &pool, .closing);
    var second = try io.concurrent(Pool.close, .{ &pool, io, Io.Duration.zero });
    defer second.cancel(io);
    back = true;
    pool.checkIn(io, entry, .ok);
    pool.leave(io);
    second.await(io);
    // The second returned once the first was done.
    try testing.expectEqual(Pool.State.closed, pool.state);
    first.await(io);
    const start = time.now(io);
    pool.close(io, .zero);
    try testing.expect(start.durationTo(time.now(io)).toMilliseconds() < 100);
    try testing.expectEqual(@as(u32, 1), fakes.destroyed.load(.acquire));
}
