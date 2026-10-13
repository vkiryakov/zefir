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
const server_error = @import("../protocol/server_error.zig");
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

/// A SID for a subscription the registry does not route, such as the inbox
/// of requests. Every SID comes from one counter, so none is used twice.
pub fn reserveSid(r: *Registry, io: Io) error{ConnectionClosed}!u64 {
    r.mutex.lockUncancelable(io);
    defer r.mutex.unlock(io);
    if (r.closed) return error.ConnectionClosed;
    const sid = r.next_sid;
    r.next_sid += 1;
    return sid;
}

/// How many subscriptions are registered; tests use it.
pub fn count(r: *Registry, io: Io) usize {
    r.mutex.lockUncancelable(io);
    defer r.mutex.unlock(io);
    return r.subscriptions.count();
}

/// Stops routing to `sid`; nothing happens if it is not registered.
pub fn unregister(r: *Registry, io: Io, sid: u64) void {
    r.mutex.lockUncancelable(io);
    defer r.mutex.unlock(io);
    _ = r.subscriptions.remove(sid);
}

/// How many bytes subscription `sid` holds, when it exists and takes
/// messages; null otherwise. The reader allocates a message only for such
/// a subscription, and only one that fits in it.
pub fn accepts(r: *Registry, io: Io, sid: u64) ?usize {
    r.mutex.lockUncancelable(io);
    defer r.mutex.unlock(io);
    const sub = r.subscriptions.get(sid) orelse return null;
    if (!sub.messages.isOpen(io)) return null;
    return sub.messages.limits.bytes;
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

/// The server refused a subscription: the one it names ends with
/// `.permission_denied`, and its SID comes back; null when none matches.
/// A text without a SID names a subject and a queue group, and then it is
/// the oldest open subscription with both: the server answers SUBs in
/// order.
pub fn deny(r: *Registry, io: Io, permission: server_error.Permission) ?u64 {
    r.mutex.lockUncancelable(io);
    defer r.mutex.unlock(io);
    var chosen: ?*Subscription = null;
    if (permission.sid) |sid| {
        chosen = r.subscriptions.get(sid);
    } else {
        var subscriptions = r.subscriptions.valueIterator();
        while (subscriptions.next()) |entry| {
            const sub = entry.*;
            if (chosen) |earlier| if (earlier.sid < sub.sid) continue;
            if (!server_error.quotedEql(permission.subject, sub.subject)) continue;
            if (!sameQueue(permission.queue, sub.queue_group)) continue;
            if (!sub.messages.isOpen(io)) continue;
            chosen = sub;
        }
    }
    const sub = chosen orelse return null;
    if (!sub.messages.end(io, .permission_denied, false)) return null;
    return sub.sid;
}

/// The queue group the server quoted, if any, is `queue`.
fn sameQueue(quoted: ?[]const u8, queue: ?[]const u8) bool {
    const q = quoted orelse return queue == null;
    return queue != null and server_error.quotedEql(q, queue.?);
}

/// The client closed: every subscription ends with `.closed`, and no new
/// one registers.
pub fn closeAll(r: *Registry, io: Io) void {
    r.mutex.lockUncancelable(io);
    defer r.mutex.unlock(io);
    r.closed = true;
    var subscriptions = r.subscriptions.valueIterator();
    while (subscriptions.next()) |sub| _ = sub.*.messages.end(io, .closed, true);
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

test "a reserved SID is never given to a subscription, and none is reserved once closed" {
    const io = testing.io;
    var r: Registry = .{};
    defer r.deinit(testing.allocator);
    const a = try newSubscription(testing.allocator, "a");
    try r.register(io, testing.allocator, a, 10);
    try testing.expectEqual(2, try r.reserveSid(io));
    const b = try newSubscription(testing.allocator, "b");
    try r.register(io, testing.allocator, b, 10);
    try testing.expectEqual(3, b.sid);
    // A reserved SID routes nothing.
    try testing.expect(r.accepts(io, 2) == null);
    r.closeAll(io);
    try testing.expectError(error.ConnectionClosed, r.reserveSid(io));
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

test "deny ends the oldest open subscription with the subject and queue the server names" {
    const io = testing.io;
    var r: Registry = .{};
    defer r.deinit(testing.allocator);
    const limits: MessageQueue.Limits = .{ .messages = 4, .bytes = 1024 };
    var subs: [4]*Subscription = undefined;
    for (&subs, [_][]const u8{ "forbidden", "forbidden", "forbidden", "x.q\"uo\\te.ü" }, [_]?[]const u8{ null, null, "g", null }) |*sub, subject, queue| {
        sub.* = try create(testing.allocator, undefined, subject, .{ .queue = queue }, limits);
        try r.register(io, testing.allocator, sub.*, 10);
    }
    const forbidden: server_error.Permission = .{ .operation = .subscribe, .subject = "forbidden" };
    try testing.expectEqual(1, r.deny(io, forbidden).?);
    try testing.expectEqual(.permission_denied, subs[0].messages.endedHow(io).?);
    try testing.expectEqual(2, r.deny(io, forbidden).?);
    // The one in a queue group is not named by a text without the group.
    try testing.expect(r.deny(io, forbidden) == null);
    try testing.expectEqual(3, r.deny(io, .{ .operation = .subscribe, .subject = "forbidden", .queue = "g" }).?);
    // The server escapes the subject; the match does not mind.
    try testing.expectEqual(4, r.deny(io, .{ .operation = .subscribe, .subject = "x.q\\\"uo\\\\te.ü" }).?);
}

test "deny takes the SID when the server names it" {
    const io = testing.io;
    var r: Registry = .{};
    defer r.deinit(testing.allocator);
    const a = try newSubscription(testing.allocator, "dup");
    try r.register(io, testing.allocator, a, 10);
    const b = try newSubscription(testing.allocator, "dup");
    try r.register(io, testing.allocator, b, 10);
    try testing.expectEqual(2, r.deny(io, .{ .operation = .subscribe, .subject = "dup", .sid = 2 }).?);
    try testing.expect(a.messages.isOpen(io));
    try testing.expect(!b.messages.isOpen(io));
    try testing.expect(r.deny(io, .{ .operation = .subscribe, .subject = "dup", .sid = 99 }) == null);
}
