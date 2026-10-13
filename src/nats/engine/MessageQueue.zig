//! The messages of one subscription that wait for `next()`: as many as its
//! limits allow, by count and by bytes, and its overflow policy decides
//! about more. Once the queue ends, `next()` hands out what it holds and
//! then says how it ended.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Message = @import("../Message.zig");
const Subscription = @import("../Subscription.zig");
const OverflowPolicy = Subscription.OverflowPolicy;
const time = @import("time.zig");
const MessageQueue = @This();

pub const Limits = struct {
    messages: u32,
    /// The bytes of the messages' allocations.
    bytes: usize,
};

/// How a queue ended.
pub const End = enum {
    /// Unsubscribed, or its last message came: `next()` returns null once
    /// the queue is empty.
    finished,
    /// A message did not fit under `close_subscription`.
    slow_consumer,
    /// The server refused the subscription.
    permission_denied,
    /// The client closed: `next()` fails at once, and the messages are
    /// gone.
    closed,
};

gpa: Allocator,
limits: Limits,
overflow: OverflowPolicy,
/// The queue finishes once this many messages came; null: never.
last: ?u64,
/// Guards everything below.
mutex: Io.Mutex = .init,
/// Signaled when a message comes or the queue ends.
not_empty: Io.Condition = .init,
/// The messages, oldest first.
messages: std.Deque(Message) = .empty,
/// The bytes of the messages queued.
bytes: usize = 0,
ended: ?End = null,
/// A task waits in `next`.
receiving: bool = false,
/// Messages that came, kept or dropped: the server counts them so for
/// `max_messages`.
received: u64 = 0,
/// Messages `next` handed out.
delivered: u64 = 0,
/// Messages lost: they did not fit, were too large, or found no memory.
dropped: u64 = 0,
/// The last message that came did not fit: a slow consumer, warned about
/// once per run of drops.
overflowing: bool = false,

pub fn init(gpa: Allocator, limits: Limits, overflow: OverflowPolicy, last: ?u64) MessageQueue {
    return .{ .gpa = gpa, .limits = limits, .overflow = overflow, .last = last };
}

/// Frees the queue and every message in it.
pub fn deinit(q: *MessageQueue) void {
    q.freeAll();
    q.messages.deinit(q.gpa);
    q.* = undefined;
}

/// The queue takes messages: it has not ended.
pub fn isOpen(q: *MessageQueue, io: Io) bool {
    q.mutex.lockUncancelable(io);
    defer q.mutex.unlock(io);
    return q.ended == null;
}

/// How the queue ended; null while it is open.
pub fn endedHow(q: *MessageQueue, io: Io) ?End {
    q.mutex.lockUncancelable(io);
    defer q.mutex.unlock(io);
    return q.ended;
}

/// Ends the queue `how`, unless it has ended already; `.closed` replaces
/// any other end. With `discard`, the messages it holds are freed; `.closed`
/// always frees them.
pub fn end(q: *MessageQueue, io: Io, how: End, discard: bool) void {
    q.mutex.lockUncancelable(io);
    defer q.mutex.unlock(io);
    if (q.ended != null and how != .closed) return;
    q.ended = how;
    if (discard or how == .closed) q.freeAll();
    q.not_empty.broadcast(io);
}

/// What a push did.
pub const Pushed = struct {
    /// Messages dropped: the one that came, or older ones.
    dropped: u64 = 0,
    /// A message did not fit after the last one did: the subscription
    /// turned into a slow consumer.
    overflow_began: bool = false,
    /// No memory to queue the message.
    no_memory: bool = false,
    /// The queue ended with this message.
    ended: ?End = null,
};

/// Queues a message that came for the subscription, or counts one that
/// came but could not be kept (null: too large, no memory). A queue that
/// has ended takes nothing and counts nothing.
pub fn push(q: *MessageQueue, io: Io, message: ?Message) Pushed {
    q.mutex.lockUncancelable(io);
    defer q.mutex.unlock(io);
    var pushed: Pushed = .{};
    if (q.ended != null) {
        if (message) |m| release(m);
        return pushed;
    }
    q.received += 1;
    if (message) |m| {
        if (q.fits(m)) {
            q.append(io, m, &pushed);
        } else {
            release(m);
            pushed.dropped = 1;
            pushed.overflow_began = !q.overflowing;
            q.overflowing = true;
        }
    } else {
        pushed.dropped = 1;
    }
    q.dropped += pushed.dropped;
    if (q.last) |last| {
        if (q.received >= last) {
            q.ended = .finished;
            pushed.ended = .finished;
            q.not_empty.broadcast(io);
        }
    }
    return pushed;
}

/// There is room for `m` within both limits.
fn fits(q: *const MessageQueue, m: Message) bool {
    return q.messages.len < q.limits.messages and m.buffer.len <= q.limits.bytes - q.bytes;
}

fn append(q: *MessageQueue, io: Io, m: Message, pushed: *Pushed) void {
    q.messages.pushBack(q.gpa, m) catch {
        release(m);
        pushed.dropped += 1;
        pushed.no_memory = true;
        return;
    };
    q.bytes += m.buffer.len;
    q.overflowing = false;
    q.not_empty.signal(io);
}

/// Takes the oldest message, waiting for one until `timeout`. After the
/// queue ends, the messages it holds come out first, then null or the
/// error of its end; `.closed` fails at once.
pub fn next(q: *MessageQueue, io: Io, timeout: Io.Timeout) Subscription.NextError!?Message {
    const deadline = time.deadline(io, timeout);
    try q.mutex.lock(io);
    defer q.mutex.unlock(io);
    if (q.receiving) return error.ConcurrentReceive;
    q.receiving = true;
    defer q.receiving = false;
    while (true) {
        if (q.ended == .closed) return error.ConnectionClosed;
        if (q.messages.popFront()) |m| {
            q.bytes -= m.buffer.len;
            q.delivered += 1;
            return m;
        }
        if (q.ended) |how| return switch (how) {
            .finished => null,
            .slow_consumer => error.SlowConsumer,
            .permission_denied => error.PermissionDenied,
            .closed => unreachable,
        };
        try q.not_empty.waitTimeout(io, &q.mutex, time.until(deadline));
    }
}

fn release(message: Message) void {
    var m = message;
    m.deinit();
}

fn freeAll(q: *MessageQueue) void {
    while (q.messages.popFront()) |m| release(m);
    q.bytes = 0;
}

const testing = std.testing;

test "a queue is open until it ends, and closed wins over any other end" {
    const io = testing.io;
    var q: MessageQueue = .init(testing.allocator, .{ .messages = 4, .bytes = 1024 }, .drop_newest, null);
    defer q.deinit();
    try testing.expect(q.isOpen(io));
    q.end(io, .permission_denied, false);
    try testing.expect(!q.isOpen(io));
    q.end(io, .finished, false);
    try testing.expectEqual(.permission_denied, q.endedHow(io).?);
    q.end(io, .closed, false);
    try testing.expectEqual(.closed, q.endedHow(io).?);
}
