//! The client's subscriptions by SID: the reader routes each message
//! through it. `subscribe` registers a subscription, its `deinit` takes it
//! away, and the client's `deinit` frees whatever is left.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Client = @import("../Client.zig");
const Subscription = @import("../Subscription.zig");
const Message = @import("../Message.zig");
const MessageQueue = @import("MessageQueue.zig");
const Outbound = @import("Outbound.zig");
const encoder = @import("../protocol/encoder.zig");
const Registry = @This();

/// Guards everything below.
mutex: Io.Mutex = .init,
subscriptions: std.AutoHashMapUnmanaged(u64, *Subscription) = .empty,
/// The SID of the next subscription. SIDs are never reused, so a message
/// late for an old subscription cannot reach a new one.
next_sid: u64 = 1,
/// The client closed: no new subscriptions.
closed: bool = false,

pub const RegisterError = error{ TooManySubscriptions, ConnectionClosed, OutOfMemory };

/// Gives `sub` the next SID and routes messages for it to it. At most
/// `max` subscriptions are registered at once.
pub fn register(r: *Registry, io: Io, gpa: Allocator, sub: *Subscription, max: u32) RegisterError!void {
    r.mutex.lockUncancelable(io);
    defer r.mutex.unlock(io);
    if (r.closed) return error.ConnectionClosed;
    if (r.subscriptions.count() >= max) return error.TooManySubscriptions;
    try r.subscriptions.ensureUnusedCapacity(gpa, 1);
    sub.sid = r.next_sid;
    r.next_sid += 1;
    r.subscriptions.putAssumeCapacityNoClobber(sub.sid, sub);
}

/// Stops routing to `sid`; nothing happens if it is not registered.
pub fn unregister(r: *Registry, io: Io, sid: u64) void {
    r.mutex.lockUncancelable(io);
    defer r.mutex.unlock(io);
    _ = r.subscriptions.remove(sid);
}

/// Subscription `sid` exists and takes messages: the reader allocates a
/// message only then.
pub fn accepts(r: *Registry, io: Io, sid: u64) bool {
    r.mutex.lockUncancelable(io);
    defer r.mutex.unlock(io);
    const sub = r.subscriptions.get(sid) orelse return false;
    return sub.messages.isOpen(io);
}

/// Hands `message` to subscription `sid`, or tells it that a message came
/// that could not be kept (null). Null when there is no such subscription
/// any more: the message is freed.
pub fn deliver(r: *Registry, io: Io, sid: u64, message: ?Message) ?MessageQueue.Pushed {
    r.mutex.lockUncancelable(io);
    defer r.mutex.unlock(io);
    const sub = r.subscriptions.get(sid) orelse {
        if (message) |m| {
            var dropped = m;
            dropped.deinit();
        }
        return null;
    };
    return sub.messages.push(io, message);
}

/// The client closed: every subscription ends with `.closed`, and no new
/// one registers.
pub fn closeAll(r: *Registry, io: Io) void {
    r.mutex.lockUncancelable(io);
    defer r.mutex.unlock(io);
    r.closed = true;
    var subscriptions = r.subscriptions.valueIterator();
    while (subscriptions.next()) |sub| sub.*.messages.end(io, .closed, true);
}

/// Frees every subscription still registered: the client goes away.
pub fn deinit(r: *Registry, gpa: Allocator) void {
    var subscriptions = r.subscriptions.valueIterator();
    while (subscriptions.next()) |sub| destroy(gpa, sub.*);
    r.subscriptions.deinit(gpa);
    r.* = undefined;
}

/// A subscription of `client` to `subject`, with its own copies of the
/// subject and the queue group; it gets its SID when registered.
pub fn create(gpa: Allocator, client: *Client, subject: []const u8, options: Subscription.Options, limits: MessageQueue.Limits) Allocator.Error!*Subscription {
    const sub = try gpa.create(Subscription);
    errdefer gpa.destroy(sub);
    const subject_copy = try gpa.dupe(u8, subject);
    errdefer gpa.free(subject_copy);
    const queue_copy = if (options.queue) |queue| try gpa.dupe(u8, queue) else null;
    sub.* = .{
        .client = client,
        .sid = 0,
        .subject = subject_copy,
        .queue_group = queue_copy,
        .messages = .init(gpa, limits, options.overflow, options.max_messages),
    };
    return sub;
}

/// Frees `sub` and the messages it holds; it must not be registered.
pub fn destroy(gpa: Allocator, sub: *Subscription) void {
    sub.messages.deinit();
    if (sub.queue_group) |queue| gpa.free(queue);
    gpa.free(sub.subject);
    gpa.destroy(sub);
}

/// Queues `UNSUB sid` at once: no wait for room, so the reader and
/// `deinit` can use it. A subscription sends it at most once, which keeps
/// what goes over the outbound limit bounded.
pub fn queueUnsub(outbound: *Outbound, io: Io, sid: u64) Outbound.PutNowError!void {
    return outbound.putNow(io, .service, encoder.unsubLen(sid, null), encoder.writeUnsub, .{ sid, null });
}

const testing = std.testing;

fn newSubscription(gpa: Allocator, subject: []const u8) !*Subscription {
    // The registry never looks at the client.
    return create(gpa, undefined, subject, .{}, .{ .messages = 4, .bytes = 1024 });
}

test "SIDs start at 1, grow, and are never reused" {
    const io = testing.io;
    var r: Registry = .{};
    defer r.deinit(testing.allocator);
    const a = try newSubscription(testing.allocator, "a");
    try r.register(io, testing.allocator, a, 10);
    try testing.expectEqual(1, a.sid);
    const b = try newSubscription(testing.allocator, "b");
    try r.register(io, testing.allocator, b, 10);
    try testing.expectEqual(2, b.sid);
    r.unregister(io, a.sid);
    destroy(testing.allocator, a);
    const c = try newSubscription(testing.allocator, "c");
    try r.register(io, testing.allocator, c, 10);
    try testing.expectEqual(3, c.sid);
}

test "no more than the limit at once, and none once closed" {
    const io = testing.io;
    var r: Registry = .{};
    defer r.deinit(testing.allocator);
    const a = try newSubscription(testing.allocator, "a");
    try r.register(io, testing.allocator, a, 1);
    const b = try newSubscription(testing.allocator, "b");
    try testing.expectError(error.TooManySubscriptions, r.register(io, testing.allocator, b, 1));
    r.unregister(io, a.sid);
    destroy(testing.allocator, a);
    try r.register(io, testing.allocator, b, 1);

    r.closeAll(io);
    try testing.expectEqual(.closed, b.messages.endedHow(io).?);
    const c = try newSubscription(testing.allocator, "c");
    defer destroy(testing.allocator, c);
    try testing.expectError(error.ConnectionClosed, r.register(io, testing.allocator, c, 10));
}

test "unregistering an unknown SID changes nothing" {
    const io = testing.io;
    var r: Registry = .{};
    defer r.deinit(testing.allocator);
    r.unregister(io, 42);
    const a = try newSubscription(testing.allocator, "a");
    try r.register(io, testing.allocator, a, 10);
    r.unregister(io, 42);
    try testing.expectEqual(1, r.subscriptions.count());
}

fn createAndDestroy(gpa: Allocator) !void {
    const sub = try create(gpa, undefined, "orders.*", .{ .queue = "workers" }, .{ .messages = 4, .bytes = 1024 });
    destroy(gpa, sub);
}

test "nothing leaks when an allocation fails" {
    try testing.checkAllAllocationFailures(testing.allocator, createAndDestroy, .{});
}
