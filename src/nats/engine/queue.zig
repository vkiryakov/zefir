//! A bounded queue whose one consumer waits for an item, a deadline, the
//! cancellation of its task or `close()`. Producers never wait: a full
//! queue is theirs to handle. Nothing in the client uses it now: events go
//! through `events.Queue`, which keeps `closed` apart and grows on demand,
//! and a subscription's messages through `MessageQueue`, which also bounds
//! their bytes.

const std = @import("std");
const Io = std.Io;
const time = @import("time.zig");

pub fn Queue(comptime T: type) type {
    return struct {
        const Self = @This();

        mutex: Io.Mutex = .init,
        not_empty: Io.Condition = .init,
        /// A ring: `len` items from `head` on.
        buffer: []T,
        head: usize = 0,
        len: usize = 0,
        closed: bool = false,
        /// A consumer waits in `next`.
        receiving: bool = false,

        /// The queue holds at most `buffer.len` items.
        pub fn init(buffer: []T) Self {
            return .{ .buffer = buffer };
        }

        pub const PushError = error{ Full, Closed };

        /// Adds `item` without waiting.
        pub fn push(q: *Self, io: Io, item: T) PushError!void {
            q.mutex.lockUncancelable(io);
            defer q.mutex.unlock(io);
            if (q.closed) return error.Closed;
            if (q.len == q.buffer.len) return error.Full;
            q.buffer[(q.head + q.len) % q.buffer.len] = item;
            q.len += 1;
            q.not_empty.signal(io);
        }

        pub const NextError = error{ Timeout, Closed, Canceled, ConcurrentReceive };

        /// Takes the oldest item, waiting for one until `timeout`. One
        /// consumer at a time: a second one gets ConcurrentReceive. After
        /// `close()` the items already queued still come out, then Closed.
        pub fn next(q: *Self, io: Io, timeout: Io.Timeout) NextError!T {
            const deadline = time.deadline(io, timeout);
            try q.mutex.lock(io);
            defer q.mutex.unlock(io);
            if (q.receiving) return error.ConcurrentReceive;
            q.receiving = true;
            defer q.receiving = false;
            while (q.len == 0) {
                if (q.closed) return error.Closed;
                try q.not_empty.waitTimeout(io, &q.mutex, time.until(deadline));
            }
            const item = q.buffer[q.head];
            q.head = (q.head + 1) % q.buffer.len;
            q.len -= 1;
            return item;
        }

        /// Refuses new items and wakes the consumer.
        pub fn close(q: *Self, io: Io) void {
            q.mutex.lockUncancelable(io);
            defer q.mutex.unlock(io);
            q.closed = true;
            q.not_empty.broadcast(io);
        }

        /// Items waiting to be taken.
        pub fn count(q: *Self, io: Io) usize {
            q.mutex.lockUncancelable(io);
            defer q.mutex.unlock(io);
            return q.len;
        }

        fn isReceiving(q: *Self, io: Io) bool {
            q.mutex.lockUncancelable(io);
            defer q.mutex.unlock(io);
            return q.receiving;
        }
    };
}

const testing = std.testing;
const U32Queue = Queue(u32);

fn within(seconds: i64) Io.Timeout {
    return .{ .duration = .{ .raw = .fromSeconds(seconds), .clock = .awake } };
}

fn pushLater(io: Io, q: *U32Queue, item: u32, delay: Io.Duration) Io.Cancelable!void {
    try io.sleep(delay, .awake);
    q.push(io, item) catch {};
}

fn receive(io: Io, q: *U32Queue) U32Queue.NextError!u32 {
    return q.next(io, .none);
}

/// Waits until a consumer waits in `next`, so a test does not race it.
fn awaitReceiver(io: Io, q: *U32Queue) !void {
    const give_up = time.after(io, .fromSeconds(5));
    while (!q.isReceiving(io)) {
        if (time.expired(io, give_up)) return error.TestReceiverNeverWaited;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}

test "next waits for an item pushed by another task" {
    const io = testing.io;
    var buffer: [4]u32 = undefined;
    var q: U32Queue = .init(&buffer);
    var pusher = try io.concurrent(pushLater, .{ io, &q, 42, .fromMilliseconds(20) });
    defer pusher.cancel(io) catch {};
    try testing.expectEqual(42, try q.next(io, within(10)));
}

test "next gives up at the deadline, not before" {
    const io = testing.io;
    var buffer: [4]u32 = undefined;
    var q: U32Queue = .init(&buffer);
    const start = Io.Clock.awake.now(io);
    try testing.expectError(error.Timeout, q.next(io, .{ .duration = .{ .raw = .fromMilliseconds(30), .clock = .awake } }));
    try testing.expect(start.durationTo(Io.Clock.awake.now(io)).nanoseconds >= 30 * std.time.ns_per_ms);
}

test "canceling the waiting task ends next with Canceled" {
    const io = testing.io;
    var buffer: [4]u32 = undefined;
    var q: U32Queue = .init(&buffer);
    var receiver = try io.concurrent(receive, .{ io, &q });
    defer _ = receiver.cancel(io) catch 0;
    try awaitReceiver(io, &q);
    try testing.expectError(error.Canceled, receiver.cancel(io));
    // The queue works on after a canceled wait.
    try q.push(io, 7);
    try testing.expectEqual(7, try q.next(io, .none));
}

test "close wakes the waiting consumer" {
    const io = testing.io;
    var buffer: [4]u32 = undefined;
    var q: U32Queue = .init(&buffer);
    var receiver = try io.concurrent(receive, .{ io, &q });
    defer _ = receiver.cancel(io) catch 0;
    try awaitReceiver(io, &q);
    q.close(io);
    try testing.expectError(error.Closed, receiver.await(io));
}

test "items queued before close still come out, then Closed" {
    const io = testing.io;
    var buffer: [4]u32 = undefined;
    var q: U32Queue = .init(&buffer);
    try q.push(io, 1);
    try q.push(io, 2);
    q.close(io);
    try testing.expectError(error.Closed, q.push(io, 3));
    try testing.expectEqual(2, q.count(io));
    try testing.expectEqual(1, try q.next(io, .none));
    try testing.expectEqual(2, try q.next(io, .none));
    try testing.expectError(error.Closed, q.next(io, .none));
}

test "a second consumer gets ConcurrentReceive" {
    const io = testing.io;
    var buffer: [4]u32 = undefined;
    var q: U32Queue = .init(&buffer);
    var receiver = try io.concurrent(receive, .{ io, &q });
    defer _ = receiver.cancel(io) catch 0;
    try awaitReceiver(io, &q);
    try testing.expectError(error.ConcurrentReceive, q.next(io, within(1)));
    try q.push(io, 5);
    try testing.expectEqual(5, try receiver.await(io));
}

test "push to a full queue fails at once, and the order is kept around the ring" {
    const io = testing.io;
    var buffer: [2]u32 = undefined;
    var q: U32Queue = .init(&buffer);
    for (0..5) |round| {
        const base: u32 = @intCast(round * 2);
        try q.push(io, base);
        try q.push(io, base + 1);
        try testing.expectError(error.Full, q.push(io, 99));
        try testing.expectEqual(base, try q.next(io, .none));
        try testing.expectEqual(base + 1, try q.next(io, .none));
    }
    var empty: U32Queue = .init(&.{});
    try testing.expectError(error.Full, empty.push(io, 1));
}

test "the longest timeouts do not overflow" {
    const io = testing.io;
    var buffer: [4]u32 = undefined;
    var q: U32Queue = .init(&buffer);
    try q.push(io, 1);
    try testing.expectEqual(1, try q.next(io, .{ .duration = .{ .raw = .max, .clock = .awake } }));

    var pusher = try io.concurrent(pushLater, .{ io, &q, 2, .fromMilliseconds(10) });
    defer pusher.cancel(io) catch {};
    try testing.expectEqual(2, try q.next(io, .{ .deadline = .{ .raw = .{ .nanoseconds = std.math.maxInt(i96) }, .clock = .awake } }));
    try testing.expectError(error.Timeout, q.next(io, .{ .deadline = .{ .raw = .{ .nanoseconds = std.math.minInt(i96) }, .clock = .awake } }));
}
