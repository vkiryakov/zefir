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

/// A queue of `capacity` slots (a power of two), each for a record of up
/// to `max_record_bytes`.
pub fn init(gpa: std.mem.Allocator, capacity: u32, max_record_bytes: u32, io: std.Io) error{OutOfMemory}!Queue {
    std.debug.assert(capacity > 0 and std.math.isPowerOfTwo(capacity));
    const slot_size = options.slotSize(max_record_bytes);
    const slots = try gpa.alignedAlloc(u8, .fromByteUnits(std.atomic.cache_line), @as(usize, capacity) * slot_size);
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
    std.debug.assert(bytes.len <= q.slot_size - header_bytes);
    var pos = q.tail.load(.monotonic);
    const index = while (true) {
        if (pos & closed_bit != 0) return error.Closed;
        const index = pos & q.mask;
        // Acquire: the consumer's reads of this slot's last record are done.
        const dif: i64 = @bitCast(q.seq(index).load(.acquire) -% pos);
        if (dif == 0) {
            pos = q.tail.cmpxchgWeak(pos, pos + 1, .monotonic, .monotonic) orelse break index;
        } else if (dif < 0) {
            return error.Full; // the slot still holds the record of the last lap
        } else {
            pos = q.tail.load(.monotonic); // another producer took this position
        }
    };
    @memcpy(q.payload(index)[0..bytes.len], bytes);
    q.len(index).* = @intCast(bytes.len);
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
    _ = q.space_waiters.fetchAdd(1, .seq_cst);
    defer _ = q.space_waiters.fetchSub(1, .seq_cst);
    while (true) {
        // Read the epoch first: a slot freed after this read bumps it, so
        // the wait below returns at once instead of missing the wake-up.
        const epoch = q.space_epoch.load(.seq_cst);
        if (q.tryPush(bytes)) |_| return else |e| switch (e) {
            error.Closed => return error.Closed,
            error.Full => {},
        }
        q.io.futexWaitTimeout(u32, &q.space_epoch.raw, epoch, recheck) catch {};
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
