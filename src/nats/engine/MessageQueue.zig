//! The messages of one subscription that wait for `next()`: as many as its
//! limits allow, by count and by bytes, and its overflow policy decides
//! about more. Once the queue ends, `next()` hands out what it holds and
//! then says how it ended.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Message = @import("../Message.zig");
const OverflowPolicy = @import("../Subscription.zig").OverflowPolicy;
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

fn freeAll(q: *MessageQueue) void {
    while (q.messages.popFront()) |message| {
        var m = message;
        m.deinit();
    }
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
