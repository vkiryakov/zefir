//! The queue of the queued mode: bounded, many producers and one consumer
//! (Vyukov's design). A record takes one fixed slot. A producer reserves a
//! slot with one compare-and-swap, copies the record in and publishes it
//! with one store: no lock, and no system call unless the consumer sleeps
//! and has to be woken. A producer stopped between reserving and
//! publishing holds back the records after it (they wait; none is lost).

const std = @import("std");
const options = @import("options.zig");
const testing = std.testing;

const Queue = @This();

/// Set in `tail` once the queue is closed: no record gets in after that.
const closed_bit: u64 = 1 << 63;
/// A slot starts with its sequence number (u64) and the record's length
/// (u32); the record follows.
const header_bytes = 16;
/// How long a blocked producer or the sleeping consumer waits before it
/// looks again by itself: a safety net, wake-ups do not rely on it.
const recheck: std.Io.Timeout = .{ .duration = .{ .raw = .fromMilliseconds(100), .clock = .awake } };

slots: []align(std.atomic.cache_line) u8,
slot_size: usize,
mask: u64,
/// The logger's own Io: waits and wakes on both sides use the same one.
io: std.Io,
/// The next position to reserve; `closed_bit` once closed. Producers
/// compare-and-swap it.
tail: std.atomic.Value(u64) align(std.atomic.cache_line) = .init(0),
/// The next position to take; the consumer's alone.
head: u64 align(std.atomic.cache_line) = 0,
/// `head`, for other threads.
head_shared: std.atomic.Value(u64) = .init(0),
/// 1 while the consumer sleeps in `waitForWork`.
consumer_sleeping: std.atomic.Value(u32) align(std.atomic.cache_line) = .init(0),
/// Bumped each time the consumer frees slots; blocked producers wait on it.
space_epoch: std.atomic.Value(u32) align(std.atomic.cache_line) = .init(0),
space_waiters: std.atomic.Value(u32) = .init(0),

/// A queue of `capacity` slots, each for a record of up to
/// `max_record_bytes`. `capacity` is a power of two and at least 2: with
/// one slot, a published record would look like room for the next one.
pub fn init(gpa: std.mem.Allocator, capacity: u32, max_record_bytes: u32, io: std.Io) error{OutOfMemory}!Queue {
    std.debug.assert(capacity >= 2 and std.math.isPowerOfTwo(capacity));
    const slot_size = options.slotSize(max_record_bytes);
    // Too much for a 32-bit address space is too much memory.
    const bytes = std.math.mul(usize, capacity, slot_size) catch return error.OutOfMemory;
    const slots = try gpa.alignedAlloc(u8, .fromByteUnits(std.atomic.cache_line), bytes);
    var q: Queue = .{ .slots = slots, .slot_size = slot_size, .mask = capacity - 1, .io = io };
    for (0..capacity) |i| q.seq(i).* = .init(i);
    return q;
}

pub fn deinit(q: *Queue, gpa: std.mem.Allocator) void {
    gpa.free(q.slots);
}

/// The sequence number of slot `index`: equal to the position a producer
/// may reserve, or that position + 1 once the record is published.
fn seq(q: *const Queue, index: u64) *std.atomic.Value(u64) {
    return @ptrCast(@alignCast(q.slots[@intCast(index * q.slot_size)..].ptr));
}

fn len(q: *const Queue, index: u64) *u32 {
    return @ptrCast(@alignCast(q.slots[@intCast(index * q.slot_size + 8)..].ptr));
}

fn payload(q: *const Queue, index: u64) []u8 {
    return q.slots[@intCast(index * q.slot_size + header_bytes)..][0 .. q.slot_size - header_bytes];
}

/// Copies `bytes` into the queue, or fails at once: `error.Full` when no
/// slot is free, `error.Closed` after `close`.
pub fn tryPush(q: *Queue, bytes: []const u8) error{ Full, Closed }!void {
    return q.tryPushParts(&.{bytes});
}

/// `tryPush` for a record given in parts, copied in one after another.
pub fn tryPushParts(q: *Queue, parts: []const []const u8) error{ Full, Closed }!void {
    var total: usize = 0;
    for (parts) |part| total += part.len;
    std.debug.assert(total <= q.slot_size - header_bytes);
    q.publishParts(try q.reserve(), parts);
}

/// Reserves the next position: its slot is the caller's until `publish`.
pub fn reserve(q: *Queue) error{ Full, Closed }!u64 {
    var pos = q.tail.load(.monotonic);
    while (true) {
        if (pos & closed_bit != 0) return error.Closed;
        // Acquire: the consumer's reads of this slot's last record are done.
        const dif: i64 = @bitCast(q.seq(pos & q.mask).load(.acquire) -% pos);
        if (dif == 0) {
            pos = q.tail.cmpxchgWeak(pos, pos + 1, .monotonic, .monotonic) orelse return pos;
        } else if (dif < 0) {
            return error.Full; // the slot still holds the record of the last lap
        } else {
            pos = q.tail.load(.monotonic); // another producer took this position
        }
    }
}

/// Copies `bytes` into the slot of position `pos`, which `reserve` gave,
/// and hands it to the consumer.
pub fn publish(q: *Queue, pos: u64, bytes: []const u8) void {
    q.publishParts(pos, &.{bytes});
}

fn publishParts(q: *Queue, pos: u64, parts: []const []const u8) void {
    const index = pos & q.mask;
    const dest = q.payload(index);
    var filled: usize = 0;
    for (parts) |part| {
        @memcpy(dest[filled..][0..part.len], part);
        filled += part.len;
    }
    q.len(index).* = @intCast(filled);
    // seq_cst, not just release: with the load below it pairs with the
    // consumer's announcement that it sleeps, so one of the two sees the other.
    q.seq(index).store(pos + 1, .seq_cst);
    if (q.consumer_sleeping.load(.seq_cst) != 0) q.wakeConsumer();
}

/// `tryPush` that waits for a free slot instead of failing; still fails
/// with `error.Closed`. Blocks the OS thread.
pub fn pushBlocking(q: *Queue, bytes: []const u8) error{Closed}!void {
    if (q.tryPush(bytes)) |_| return else |e| switch (e) {
        error.Closed => return error.Closed,
        error.Full => {},
    }
    // Not a cancelation point: a cancel request for the caller's task stays
    // for the task's own next one.
    const protection = q.io.swapCancelProtection(.blocked);
    defer _ = q.io.swapCancelProtection(protection);
    _ = q.space_waiters.fetchAdd(1, .seq_cst);
    defer _ = q.space_waiters.fetchSub(1, .seq_cst);
    // `pop` and `close` bump `space_epoch`.
    return waitUntil(q.io, &q.space_epoch, recheck, Room{ .q = q, .bytes = bytes });
}

/// What `pushBlocking` waits for: a slot that takes its record, or the
/// close.
const Room = struct {
    q: *Queue,
    bytes: []const u8,

    fn done(r: Room) error{Closed}!bool {
        r.q.tryPush(r.bytes) catch |e| return switch (e) {
            error.Closed => error.Closed,
            error.Full => false,
        };
        return true;
    }
};

/// Sleeps until `waiter.done()` returns true, or returns its error. The
/// threads that change what `done` looks at bump `epoch` after each change
/// and wake the threads waiting on it; each sleep lasts at most `timeout`.
/// Blocked producers wait this way, and so do the logger's `flush` and
/// `shutdown`.
pub fn waitUntil(io: std.Io, epoch: *const std.atomic.Value(u32), timeout: std.Io.Timeout, waiter: anytype) !void {
    while (true) {
        // Read the epoch first: a change after this read bumps it, so the
        // sleep below returns at once instead of missing the wake-up.
        const seen = epoch.load(.seq_cst);
        if (try waiter.done()) return;
        io.futexWaitTimeout(u32, &epoch.raw, seen, timeout) catch {};
    }
}

/// For the consumer: copies the published records, up to `ends.len` of
/// them, one after another into `batch`, sets `ends[i]` to where record i
/// ends, and frees their slots before the caller writes the batch out.
/// Returns how many it took.
pub fn pop(q: *Queue, batch: []u8, ends: []usize) usize {
    var n: usize = 0;
    var used: usize = 0;
    while (n < ends.len) : (n += 1) {
        const index = q.head & q.mask;
        if (q.seq(index).load(.acquire) != q.head + 1) break; // empty, or still being copied in
        const record = q.payload(index)[0..q.len(index).*];
        if (used + record.len > batch.len) break;
        @memcpy(batch[used..][0..record.len], record);
        used += record.len;
        ends[n] = used;
        q.seq(index).store(q.head + q.mask + 1, .release); // free for the next lap
        q.head += 1;
    }
    q.head_shared.store(q.head, .monotonic);
    if (n != 0) {
        // Bump before reading the waiter count: a producer that missed the
        // free slot either sees the new epoch or is seen as a waiter.
        _ = q.space_epoch.fetchAdd(1, .seq_cst);
        if (q.space_waiters.load(.seq_cst) != 0) q.io.futexWake(u32, &q.space_epoch.raw, std.math.maxInt(u32));
    }
    return n;
}

/// Closes the queue: pushes fail with `error.Closed` from now on, and
/// blocked producers return with it. Returns the final position: every
/// record before it was accepted and will come out.
pub fn close(q: *Queue) u64 {
    const final = q.tail.fetchOr(closed_bit, .seq_cst) & ~closed_bit;
    _ = q.space_epoch.fetchAdd(1, .seq_cst);
    q.io.futexWake(u32, &q.space_epoch.raw, std.math.maxInt(u32));
    q.wakeConsumer();
    return final;
}

pub fn isClosed(q: *const Queue) bool {
    return q.tail.load(.seq_cst) & closed_bit != 0;
}

/// Positions reserved so far: every record accepted, also those a
/// producer is still copying in.
pub fn reserved(q: *const Queue) u64 {
    return q.tail.load(.seq_cst) & ~closed_bit;
}

/// Records accepted and not yet taken by the consumer.
pub fn depth(q: *const Queue) u64 {
    return q.reserved() -| q.head_shared.load(.monotonic);
}

pub const Idle = enum {
    /// Nothing reserved: the next record has yet to come.
    empty,
    /// A producer has reserved the next slot and is still copying its
    /// record in.
    filling,
    /// Closed, and every record accepted before the close was taken.
    closed,
};

/// For the consumer, after `pop` took nothing: what the queue waits for.
/// One load of `tail`, so a record reserved just before the close is never
/// mistaken for none.
pub fn idle(q: *const Queue) Idle {
    const tail = q.tail.load(.seq_cst);
    if (q.head != tail & ~closed_bit) return .filling;
    return if (tail & closed_bit != 0) .closed else .empty;
}

/// For the consumer: whether the next record is published.
pub fn ready(q: *const Queue) bool {
    return q.seq(q.head & q.mask).load(.seq_cst) == q.head + 1;
}

/// For the consumer: sleeps until a record is published or the queue is
/// closed, or `timeout` passes.
pub fn waitForWork(q: *Queue, timeout: std.Io.Timeout) void {
    q.consumer_sleeping.store(1, .seq_cst);
    if (q.ready() or q.isClosed()) {
        q.consumer_sleeping.store(0, .monotonic);
        return;
    }
    q.io.futexWaitTimeout(u32, &q.consumer_sleeping.raw, 1, timeout) catch {};
    q.consumer_sleeping.store(0, .monotonic);
}

/// For the consumer, while a producer copies its record into the next
/// slot: sleeps until it is published, `stop` is set (by a thread that
/// then calls `wakeConsumer`), or `timeout` passes. Unlike `waitForWork`
/// it sleeps on a closed queue too: the record still comes.
pub fn waitForPublish(q: *Queue, timeout: std.Io.Timeout, stop: *const std.atomic.Value(bool)) void {
    q.consumer_sleeping.store(1, .seq_cst);
    if (q.ready() or stop.load(.seq_cst)) {
        q.consumer_sleeping.store(0, .monotonic);
        return;
    }
    q.io.futexWaitTimeout(u32, &q.consumer_sleeping.raw, 1, timeout) catch {};
    q.consumer_sleeping.store(0, .monotonic);
}

/// Yields to a producer that fills the next slot before the consumer
/// sleeps until it publishes: a producer preempted there takes a while.
const filling_yields = 64;

/// For the consumer, after `pop` took nothing: waits for the next record,
/// at most `timeout`, and returns false once the queue is closed and
/// drained. `yields` counts the yields to a producer still filling its
/// slot; zero it after each record taken. `stop` ends a wait for such a
/// producer, see `waitForPublish`.
pub fn waitNext(q: *Queue, timeout: std.Io.Timeout, yields: *u32, stop: *const std.atomic.Value(bool)) bool {
    switch (q.idle()) {
        .closed => return false,
        .empty => q.waitForWork(timeout),
        .filling => if (yields.* < filling_yields) {
            yields.* += 1;
            std.Thread.yield() catch {};
        } else {
            q.waitForPublish(timeout, stop);
        },
    }
    return true;
}

/// Wakes the consumer if it sleeps.
pub fn wakeConsumer(q: *Queue) void {
    if (q.consumer_sleeping.swap(0, .seq_cst) != 0) q.io.futexWake(u32, &q.consumer_sleeping.raw, 1);
}

/// Pops everything published and returns the records as one string, one
/// record per line.
fn drainLines(q: *Queue, out: *std.Io.Writer.Allocating) !void {
    var batch: [16 * 64]u8 = undefined;
    var ends: [16]usize = undefined;
    while (true) {
        const n = q.pop(&batch, &ends);
        if (n == 0) return;
        var start: usize = 0;
        for (ends[0..n]) |end| {
            try out.writer.writeAll(batch[start..end]);
            try out.writer.writeByte('\n');
            start = end;
        }
    }
}

test "records come out in the order they went in, lap after lap" {
    var threaded: std.Io.Threaded = .init_single_threaded;
    var q = try Queue.init(testing.allocator, 4, 64, threaded.io());
    defer q.deinit(testing.allocator);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var want: std.Io.Writer.Allocating = .init(testing.allocator);
    defer want.deinit();
    var buf: [16]u8 = undefined;
    for (0..10) |lap| {
        for (0..4) |i| {
            const record = try std.fmt.bufPrint(&buf, "r{d}-{d}", .{ lap, i });
            try q.tryPush(record);
            try want.writer.print("{s}\n", .{record});
        }
        try testing.expectError(error.Full, q.tryPush("one too many"));
        try testing.expectEqual(@as(u64, 4), q.depth());
        try drainLines(&q, &out);
        try testing.expectEqual(@as(u64, 0), q.depth());
    }
    try testing.expectEqualStrings(want.written(), out.written());
}

test "pop takes at most what the batch holds and leaves the rest" {
    var threaded: std.Io.Threaded = .init_single_threaded;
    var q = try Queue.init(testing.allocator, 8, 64, threaded.io());
    defer q.deinit(testing.allocator);
    for ("abcde") |c| try q.tryPush(&.{c});
    var batch: [64]u8 = undefined;
    var ends: [2]usize = undefined;
    try testing.expectEqual(@as(usize, 2), q.pop(&batch, &ends));
    try testing.expectEqualStrings("ab", batch[0..ends[1]]);
    try testing.expectEqual(@as(u64, 3), q.depth());
}

test "a closed queue refuses records; those accepted before still come out" {
    var threaded: std.Io.Threaded = .init_single_threaded;
    var q = try Queue.init(testing.allocator, 8, 64, threaded.io());
    defer q.deinit(testing.allocator);
    try q.tryPush("one");
    try q.tryPush("two");
    try testing.expectEqual(@as(u64, 2), q.close());
    try testing.expectError(error.Closed, q.tryPush("three"));
    try testing.expectError(error.Closed, q.pushBlocking("three"));
    try testing.expect(q.isClosed());
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try drainLines(&q, &out);
    try testing.expectEqualStrings("one\ntwo\n", out.written());
}

const Producer = struct {
    q: *Queue,
    id: u8,
    count: u32,
    blocking: bool,
    refused: u32 = 0,

    fn run(p: *Producer) void {
        var buf: [32]u8 = undefined;
        for (0..p.count) |number| {
            const record = std.fmt.bufPrint(&buf, "{d} {d}", .{ p.id, number }) catch unreachable;
            if (p.blocking) {
                p.q.pushBlocking(record) catch unreachable;
            } else {
                p.q.tryPush(record) catch {
                    p.refused += 1;
                };
            }
        }
    }
};

/// Pops until `total` records came out, sleeping when there are none.
fn consume(q: *Queue, total: u64, out: *std.Io.Writer.Allocating) !void {
    var taken: u64 = 0;
    var batch: [16 * 64]u8 = undefined;
    var ends: [16]usize = undefined;
    while (taken < total) {
        const n = q.pop(&batch, &ends);
        if (n == 0) {
            q.waitForWork(.{ .duration = .{ .raw = .fromMilliseconds(50), .clock = .awake } });
            continue;
        }
        var start: usize = 0;
        for (ends[0..n]) |end| {
            try out.writer.writeAll(batch[start..end]);
            try out.writer.writeByte('\n');
            start = end;
        }
        taken += n;
    }
}

/// Checks the lines `consume` wrote: each producer's records are in order,
/// none is doubled, and `delivered[id]` counts them.
fn checkOrder(lines: []const u8, delivered: []u32, complete: bool) !void {
    var next: [8]u32 = @splat(0);
    var it = std.mem.splitScalar(u8, lines, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        var parts = std.mem.splitScalar(u8, line, ' ');
        const id = try std.fmt.parseInt(usize, parts.next().?, 10);
        const number = try std.fmt.parseInt(u32, parts.next().?, 10);
        if (complete) try testing.expectEqual(next[id], number) else try testing.expect(number >= next[id]);
        next[id] = number + 1;
        delivered[id] += 1;
    }
}

test "producers on many threads, blocking: nothing lost or doubled, each producer's order kept" {
    var threaded: std.Io.Threaded = .init_single_threaded;
    var q = try Queue.init(testing.allocator, 16, 64, threaded.io());
    defer q.deinit(testing.allocator);
    var producers: [8]Producer = undefined;
    var threads: [8]std.Thread = undefined;
    for (&producers, &threads, 0..) |*p, *t, i| {
        p.* = .{ .q = &q, .id = @intCast(i), .count = 2000, .blocking = true };
        t.* = try std.Thread.spawn(.{}, Producer.run, .{p});
    }
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try consume(&q, 8 * 2000, &out);
    for (threads) |t| t.join();
    var delivered: [8]u32 = @splat(0);
    try checkOrder(out.written(), &delivered, true);
    for (delivered) |count| try testing.expectEqual(@as(u32, 2000), count);
}

test "producers on many threads, dropping: what came out and what was refused add up" {
    var threaded: std.Io.Threaded = .init_single_threaded;
    var q = try Queue.init(testing.allocator, 8, 64, threaded.io());
    defer q.deinit(testing.allocator);
    var producers: [8]Producer = undefined;
    var threads: [8]std.Thread = undefined;
    for (&producers, &threads, 0..) |*p, *t, i| {
        p.* = .{ .q = &q, .id = @intCast(i), .count = 2000, .blocking = false };
        t.* = try std.Thread.spawn(.{}, Producer.run, .{p});
    }
    for (threads) |t| t.join();
    _ = q.close();
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try drainLines(&q, &out);
    var delivered: [8]u32 = @splat(0);
    try checkOrder(out.written(), &delivered, false);
    for (producers, delivered) |p, count| try testing.expectEqual(@as(u32, 2000), count + p.refused);
}

fn pushOne(q: *Queue, result: *?anyerror) void {
    q.pushBlocking("late") catch |e| {
        result.* = e;
        return;
    };
    result.* = null;
}

test "a blocked producer goes on when room is freed, and gets Closed when the queue closes" {
    var threaded: std.Io.Threaded = .init_single_threaded;
    var q = try Queue.init(testing.allocator, 2, 64, threaded.io());
    defer q.deinit(testing.allocator);
    try q.tryPush("a");
    try q.tryPush("b");
    var result: ?anyerror = error.TestUnexpectedResult;
    var producer = try std.Thread.spawn(.{}, pushOne, .{ &q, &result });
    var batch: [64]u8 = undefined;
    var ends: [1]usize = undefined;
    try testing.expectEqual(@as(usize, 1), q.pop(&batch, &ends)); // room for "late"
    producer.join();
    try testing.expectEqual(@as(?anyerror, null), result);

    // Full again ("b" and "late"): the next producer waits until the close.
    producer = try std.Thread.spawn(.{}, pushOne, .{ &q, &result });
    try testing.io.sleep(.fromMilliseconds(10), .awake);
    _ = q.close();
    producer.join();
    try testing.expectEqual(@as(?anyerror, error.Closed), result);
}

fn sleepUntilWork(q: *Queue, woke: *std.atomic.Value(bool)) void {
    q.waitForWork(.none);
    woke.store(true, .seq_cst);
}

test "a sleeping consumer is woken by a push" {
    var threaded: std.Io.Threaded = .init_single_threaded;
    var q = try Queue.init(testing.allocator, 4, 64, threaded.io());
    defer q.deinit(testing.allocator);
    var woke: std.atomic.Value(bool) = .init(false);
    const consumer = try std.Thread.spawn(.{}, sleepUntilWork, .{ &q, &woke });
    try testing.io.sleep(.fromMilliseconds(10), .awake);
    try q.tryPush("wake up");
    consumer.join();
    try testing.expect(woke.load(.seq_cst));
}

test "after an empty pop: empty, a record still being copied in, or closed and drained" {
    var threaded: std.Io.Threaded = .init_single_threaded;
    var q = try Queue.init(testing.allocator, 8, 64, threaded.io());
    defer q.deinit(testing.allocator);
    try testing.expectEqual(Idle.empty, q.idle());
    const pos = try q.reserve();
    try testing.expectEqual(Idle.filling, q.idle());
    // Closed while that record is still being copied in: it was accepted,
    // so the queue is not drained until the consumer has taken it.
    _ = q.close();
    try testing.expectEqual(Idle.filling, q.idle());
    q.publish(pos, "late");
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try drainLines(&q, &out);
    try testing.expectEqualStrings("late\n", out.written());
    try testing.expectEqual(Idle.closed, q.idle());
}

test "a producer stopped between reserving and publishing holds back the records after it, and loses none" {
    var threaded: std.Io.Threaded = .init_single_threaded;
    var q = try Queue.init(testing.allocator, 8, 64, threaded.io());
    defer q.deinit(testing.allocator);
    try q.tryPush("a");
    const stopped = try q.reserve(); // its producer stops here
    try q.tryPush("c");
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try drainLines(&q, &out);
    try testing.expectEqualStrings("a\n", out.written());
    try testing.expectEqual(@as(u64, 2), q.depth());
    q.publish(stopped, "b"); // and goes on
    try drainLines(&q, &out);
    try testing.expectEqualStrings("a\nb\nc\n", out.written());
}

/// How long a woken thread may take before its wake-up counts as lost.
const patience_ms = 500;

/// Takes `rounds` records one at a time, sleeping whenever none is there,
/// and counts the sleeps that ran out with a record waiting: lost
/// wake-ups. After one it only finishes the rounds, without sleeping.
fn consumeRounds(q: *Queue, rounds: usize, lost: *std.atomic.Value(u32)) void {
    var batch: [64]u8 = undefined;
    var ends: [1]usize = undefined;
    var taken: usize = 0;
    const patience: std.Io.Timeout = .{ .duration = .{ .raw = .fromMilliseconds(patience_ms), .clock = .awake } };
    while (taken < rounds) {
        if (q.pop(&batch, &ends) == 1) {
            taken += 1;
            continue;
        }
        if (lost.load(.seq_cst) > 0) {
            std.Thread.yield() catch {};
            continue;
        }
        const start = std.Io.Clock.awake.now(q.io);
        q.waitForWork(patience);
        const slept = start.durationTo(std.Io.Clock.awake.now(q.io));
        if (q.ready() and slept.nanoseconds >= patience_ms * std.time.ns_per_ms) _ = lost.fetchAdd(1, .seq_cst);
    }
}

test "lost wake-up detector: a consumer that sleeps between pushes is always woken" {
    var threaded: std.Io.Threaded = .init_single_threaded;
    var q = try Queue.init(testing.allocator, 4, 64, threaded.io());
    defer q.deinit(testing.allocator);
    const rounds = 2000;
    var lost: std.atomic.Value(u32) = .init(0);
    const consumer = try std.Thread.spawn(.{}, consumeRounds, .{ &q, rounds, &lost });
    for (0..rounds) |round| {
        // Push at once, right after the consumer says it sleeps, or a little
        // later: the race sits in each of these windows.
        switch (round % 3) {
            0 => {},
            1 => while (q.consumer_sleeping.load(.seq_cst) == 0 and q.depth() == 0 and lost.load(.seq_cst) == 0) {
                std.Thread.yield() catch {};
            },
            else => for (0..round % 7) |_| std.Thread.yield() catch {},
        }
        try q.pushBlocking("x");
    }
    consumer.join();
    try testing.expectEqual(@as(u32, 0), lost.load(.seq_cst));
}

/// The producer's side of the detector below.
const Pusher = struct {
    q: *Queue,
    rounds: usize,
    /// Pushes done so far.
    pushed: std.atomic.Value(usize) = .init(0),
    /// Pushes that waited as long as the 100 ms recheck: the room made for
    /// them did not wake them. The pusher stops at the first.
    lost: std.atomic.Value(u32) = .init(0),
    done: std.atomic.Value(bool) = .init(false),

    fn run(p: *Pusher) void {
        defer p.done.store(true, .seq_cst);
        for (0..p.rounds) |_| {
            const start = std.Io.Clock.awake.now(p.q.io);
            p.q.pushBlocking("x") catch return;
            const waited = start.durationTo(std.Io.Clock.awake.now(p.q.io));
            if (waited.nanoseconds >= 90 * std.time.ns_per_ms) {
                _ = p.lost.fetchAdd(1, .seq_cst);
                return;
            }
            _ = p.pushed.fetchAdd(1, .seq_cst);
        }
    }
};

test "lost wake-up detector: a producer that waits for room is woken as soon as there is some" {
    var threaded: std.Io.Threaded = .init_single_threaded;
    var q = try Queue.init(testing.allocator, 2, 64, threaded.io());
    defer q.deinit(testing.allocator);
    try q.tryPush("x");
    try q.tryPush("x"); // full: every push below waits for room
    var pusher: Pusher = .{ .q = &q, .rounds = 500 };
    const thread = try std.Thread.spawn(.{}, Pusher.run, .{&pusher});
    var batch: [64]u8 = undefined;
    var ends: [1]usize = undefined;
    for (0..pusher.rounds) |round| {
        while (q.space_waiters.load(.seq_cst) == 0 and !pusher.done.load(.seq_cst)) std.Thread.yield() catch {};
        if (pusher.done.load(.seq_cst)) break;
        // Room at once, or a moment later, when the producer sleeps and
        // has to be woken.
        if (round % 2 == 1) testing.io.sleep(.fromMicroseconds(500), .awake) catch {};
        _ = q.pop(&batch, &ends);
        while (pusher.pushed.load(.seq_cst) <= round and !pusher.done.load(.seq_cst)) std.Thread.yield() catch {};
    }
    thread.join();
    try testing.expectEqual(@as(u32, 0), pusher.lost.load(.seq_cst));
}

/// Takes `rounds` records one at a time. Whenever the next slot is still
/// being filled it goes straight to `waitForPublish`, past the yields, and
/// counts the waits that ran out with the record published: lost
/// wake-ups. After one it only finishes the rounds, without sleeping; it
/// returns early once the queue is closed and drained.
fn consumeFilling(q: *Queue, rounds: usize, lost: *std.atomic.Value(u32)) void {
    var batch: [64]u8 = undefined;
    var ends: [1]usize = undefined;
    var taken: usize = 0;
    const stop: std.atomic.Value(bool) = .init(false);
    const patience: std.Io.Timeout = .{ .duration = .{ .raw = .fromMilliseconds(patience_ms), .clock = .awake } };
    while (taken < rounds) {
        if (q.pop(&batch, &ends) == 1) {
            taken += 1;
            continue;
        }
        switch (q.idle()) {
            .closed => return,
            .empty => {
                std.Thread.yield() catch {};
                continue;
            },
            .filling => {},
        }
        if (lost.load(.seq_cst) > 0) {
            std.Thread.yield() catch {};
            continue;
        }
        var yields: u32 = filling_yields;
        const start = std.Io.Clock.awake.now(q.io);
        _ = q.waitNext(patience, &yields, &stop);
        const slept = start.durationTo(std.Io.Clock.awake.now(q.io));
        if (q.ready() and slept.nanoseconds >= patience_ms * std.time.ns_per_ms) _ = lost.fetchAdd(1, .seq_cst);
    }
}

test "lost wake-up detector: a consumer that waits for a slot being filled is always woken by its publish" {
    var threaded: std.Io.Threaded = .init_single_threaded;
    var q = try Queue.init(testing.allocator, 4, 64, threaded.io());
    defer q.deinit(testing.allocator);
    const rounds = 2000;
    var lost: std.atomic.Value(u32) = .init(0);
    {
        const consumer = try std.Thread.spawn(.{}, consumeFilling, .{ &q, rounds, &lost });
        // The consumer ends once it has taken every record, or at the close
        // when a round fails.
        defer {
            _ = q.close();
            consumer.join();
        }
        for (0..rounds) |round| {
            const pos = try q.reserve();
            // Publish at once, right after the consumer says it sleeps, or a
            // little later: the race sits in each of these windows.
            switch (round % 3) {
                0 => {},
                1 => while (q.consumer_sleeping.load(.seq_cst) == 0 and lost.load(.seq_cst) == 0) {
                    std.Thread.yield() catch {};
                },
                else => for (0..round % 7) |_| std.Thread.yield() catch {},
            }
            q.publish(pos, "x");
            // Taken, so the consumer has counted the wait before it.
            while (q.depth() != 0) std.Thread.yield() catch {};
        }
    }
    try testing.expectEqual(@as(u32, 0), lost.load(.seq_cst));
}

/// A sleep the waits below must not take: what they wait for came before
/// they would sleep, so they return at once.
const long_sleep: std.Io.Timeout = .{ .duration = .{ .raw = .fromMilliseconds(300), .clock = .awake } };
/// How long "at once" may take on a busy machine.
const at_once_ns = 100 * std.time.ns_per_ms;

test "a consumer about to sleep finds a record pushed after its empty pop, and does not sleep" {
    var threaded: std.Io.Threaded = .init_single_threaded;
    var q = try Queue.init(testing.allocator, 4, 64, threaded.io());
    defer q.deinit(testing.allocator);
    var batch: [64]u8 = undefined;
    var ends: [1]usize = undefined;
    try testing.expectEqual(@as(usize, 0), q.pop(&batch, &ends));
    try testing.expectEqual(Idle.empty, q.idle());
    try q.tryPush("x"); // before the consumer says it sleeps: the push wakes nobody
    const start = std.Io.Clock.awake.now(q.io);
    q.waitForWork(long_sleep);
    try testing.expect(start.durationTo(std.Io.Clock.awake.now(q.io)).nanoseconds < at_once_ns);
    try testing.expectEqual(@as(usize, 1), q.pop(&batch, &ends));
}

test "a consumer about to wait for a slot being filled finds it published, and does not sleep" {
    var threaded: std.Io.Threaded = .init_single_threaded;
    var q = try Queue.init(testing.allocator, 4, 64, threaded.io());
    defer q.deinit(testing.allocator);
    var batch: [64]u8 = undefined;
    var ends: [1]usize = undefined;
    const pos = try q.reserve();
    try testing.expectEqual(@as(usize, 0), q.pop(&batch, &ends));
    try testing.expectEqual(Idle.filling, q.idle());
    q.publish(pos, "x"); // before the consumer says it sleeps: the publish wakes nobody
    const stop: std.atomic.Value(bool) = .init(false);
    const start = std.Io.Clock.awake.now(q.io);
    q.waitForPublish(long_sleep, &stop);
    try testing.expect(start.durationTo(std.Io.Clock.awake.now(q.io)).nanoseconds < at_once_ns);
    try testing.expectEqual(@as(usize, 1), q.pop(&batch, &ends));
}

/// What `waitUntil` waits for in the test below: it changes right after
/// the first look at it, before the waiter sleeps, as it does when another
/// thread changes it then.
const ChangedAfterLook = struct {
    epoch: *std.atomic.Value(u32),
    looks: *u32,

    fn done(c: ChangedAfterLook) error{}!bool {
        c.looks.* += 1;
        if (c.looks.* > 1) return true;
        _ = c.epoch.fetchAdd(1, .seq_cst);
        return false;
    }
};

test "a wait whose condition changed between its look and its sleep looks again at once" {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    var epoch: std.atomic.Value(u32) = .init(0);
    var looks: u32 = 0;
    const start = std.Io.Clock.awake.now(io);
    try waitUntil(io, &epoch, long_sleep, ChangedAfterLook{ .epoch = &epoch, .looks = &looks });
    try testing.expect(start.durationTo(std.Io.Clock.awake.now(io)).nanoseconds < at_once_ns);
    try testing.expectEqual(@as(u32, 2), looks);
}
