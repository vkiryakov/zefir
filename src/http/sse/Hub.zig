//! The core of `http.sse.Manager(Events)`, without the
//! type of its events: the subscriptions of this process to SSE streams,
//! by key, and the queues the events go into. `Manager(Events)` writes an
//! event as the stream sends it and hands the bytes to its hub, so that a
//! subscription, which the server keeps through the end of its stream,
//! points to one type whatever the events. Internal to the module.
//!
//! A publisher never waits for delivery: the event goes into the queue of
//! each subscriber, and a subscriber whose queue goes over its limits
//! (`.queue`) is closed, so a client that falls behind costs no more
//! memory than the limits. The hub is thread-safe: zio runs the streams
//! and the publishers on several threads.
const std = @import("std");
const HttpContext = @import("../Context.zig");
const sse = @import("../sse.zig");
const flow = @import("../flow.zig");
const Subscription = @import("Subscription.zig");

const Hub = @This();
const log = std.log.scoped(.http);

gpa: std.mem.Allocator,
options: Options,
/// Guards everything below; never held across I/O.
mutex: std.Io.Mutex = .init,
/// The generation of each place a subscription took: bumped when the
/// place is free again, so that an old id never matches a new one.
generations: std.ArrayList(u32) = .empty,
/// The free places, as many as there are places at most.
free: std.ArrayList(u32) = .empty,
/// The open subscriptions of each key, under a copy of the key.
keys: std.StringHashMapUnmanaged(std.ArrayList(*Subscription)) = .empty,
/// Open subscriptions.
count: u32 = 0,
/// `deinit` has begun: no new subscription.
closing: bool = false,
/// Set when the last subscription goes after `deinit` has begun.
emptied: std.Io.Event = .unset,

/// The limits of a manager.
pub const Options = struct {
    /// Subscriptions open at once; over it `subscribe` is
    /// `error.Overloaded`, 503.
    max_subscriptions: u32 = 10_000,
    /// What waits for the client of each subscription.
    queue: Queue = .{},
    /// What happens to a subscriber whose queue would go over its limits.
    overflow: Overflow = .close,

    pub const Queue = struct {
        /// Events queued and not sent yet.
        max_events: u32 = 64,
        /// Their bytes, as the stream sends them. An event longer than this
        /// alone fits no queue: `publish` refuses it, `error.EventTooLarge`.
        max_bytes: u32 = 256 << 10,
    };

    pub const Overflow = enum {
        /// The stream closes: the client reconnects and goes on from what
        /// it shows anew.
        close,
    };
};

/// The id of a subscription: its place in the manager and the generation
/// of the place, so that an id that outlived its subscription never names
/// the next one in the same place.
pub const SubscriptionId = struct { index: u32, generation: u32 };

/// `Overloaded` (503): over the manager's `.max_subscriptions` or the
/// server's `.max_streams`. `WriteFailed`: the head of the stream did not
/// go out, or the response of the request had begun already (a second
/// `subscribe`, say; logged). `Canceled`: the request was canceled.
pub const SubscribeError = error{ Overloaded, WriteFailed, OutOfMemory } || std.Io.Cancelable;

pub fn init(gpa: std.mem.Allocator, options: Options) Hub {
    return .{ .gpa = gpa, .options = options };
}

/// Closes the streams still open, as `close` does, waits until they have
/// ended and their `.on_close` has run, and frees the hub.
pub fn deinit(hub: *Hub, io: std.Io) void {
    const open = open: {
        hub.mutex.lockUncancelable(io);
        defer hub.mutex.unlock(io);
        hub.closing = true;
        var lists = hub.keys.valueIterator();
        while (lists.next()) |list| {
            for (list.items) |sub| sub.end(io, .closed);
        }
        break :open hub.count;
    };
    // Each stream leaves the hub as it ends.
    if (open > 0) hub.emptied.waitUncancelable(io);
    hub.keys.deinit(hub.gpa);
    hub.generations.deinit(hub.gpa);
    hub.free.deinit(hub.gpa);
    hub.* = undefined;
}

/// Opens the stream of the request under `key` and returns at once, as
/// `Manager(Events).subscribe` describes it. The key is copied.
pub fn subscribe(hub: *Hub, ctx: *sse.Context, key: []const u8) SubscribeError!SubscriptionId {
    const http_ctx = ctx.internal.http;
    const io = http_ctx.io();
    if (ctx.internal.phase != .opening or http_ctx.internal.subscription != null) {
        log.warn("subscribe: the stream of this request is open already, or it has ended (request {s})", .{http_ctx.requestId()});
        return error.WriteFailed;
    }
    const server = http_ctx.internal.server orelse return error.WriteFailed;
    if (!flow.takeStream(server)) return error.Overloaded;
    errdefer flow.releaseStream(server, io);
    const sub = try Subscription.create(hub, http_ctx, key);
    errdefer sub.destroy();
    try hub.add(io, sub);
    errdefer hub.remove(io, sub);
    try openStream(http_ctx);
    flow.leaveInFlight(http_ctx);
    http_ctx.internal.subscription = sub;
    return sub.id;
}

/// The head of the stream, sent at once.
fn openStream(ctx: *HttpContext) SubscribeError!void {
    const res = &ctx.response;
    res.setHeader("cache-control", "no-cache") catch |err| return headError(ctx, err);
    res.setHeader("x-accel-buffering", "no") catch |err| return headError(ctx, err);
    var out = res.status(200).stream(.{ .content_type = "text/event-stream" }) catch |err| return headError(ctx, err);
    try out.flush();
}

fn headError(ctx: *const HttpContext, err: HttpContext.Response.StreamError) SubscribeError {
    return switch (err) {
        error.OutOfMemory, error.WriteFailed, error.Canceled => |e| e,
        // A middleware wrote the response or a body of its own.
        error.ResponseCommitted => {
            log.warn("subscribe: the response of the request has begun already; a stream needs a response of its own (request {s})", .{ctx.requestId()});
            return error.WriteFailed;
        },
        // The fields of the head are constants.
        error.InvalidHeaderValue, error.ReservedHeader => unreachable,
    };
}

/// Takes `sub` under its key, unless the hub is full or closing.
fn add(hub: *Hub, io: std.Io, sub: *Subscription) SubscribeError!void {
    hub.mutex.lockUncancelable(io);
    defer hub.mutex.unlock(io);
    if (hub.closing or hub.count >= hub.options.max_subscriptions) return error.Overloaded;
    // The memory for a new place first: past `addToKey` nothing fails.
    try hub.generations.ensureUnusedCapacity(hub.gpa, 1);
    try hub.free.ensureTotalCapacity(hub.gpa, hub.generations.items.len + 1);
    try hub.addToKey(sub);
    const index: u32 = hub.free.pop() orelse new: {
        hub.generations.appendAssumeCapacity(0);
        break :new @intCast(hub.generations.items.len - 1);
    };
    sub.id = .{ .index = index, .generation = hub.generations.items[index] };
    hub.count += 1;
}

fn addToKey(hub: *Hub, sub: *Subscription) error{OutOfMemory}!void {
    const entry = try hub.keys.getOrPut(hub.gpa, sub.key);
    if (entry.found_existing) return entry.value_ptr.append(hub.gpa, sub);
    // A new key: the hub keeps a copy of its own, which outlives the
    // subscription.
    const owned = hub.gpa.dupe(u8, sub.key) catch |err| {
        hub.keys.removeByPtr(entry.key_ptr);
        return err;
    };
    entry.key_ptr.* = owned;
    entry.value_ptr.* = .empty;
    entry.value_ptr.append(hub.gpa, sub) catch |err| {
        hub.keys.removeByPtr(entry.key_ptr);
        hub.gpa.free(owned);
        return err;
    };
}

/// Lets `sub` go, once its stream has ended and its `.on_close` has run:
/// publishers no longer reach it, and its place is free with a new
/// generation. The last one after `deinit` has begun wakes it, as the last
/// touch of the hub: `deinit` may free the hub from then on.
pub fn remove(hub: *Hub, io: std.Io, sub: *Subscription) void {
    const last = last: {
        hub.mutex.lockUncancelable(io);
        defer hub.mutex.unlock(io);
        if (hub.keys.getPtr(sub.key)) |list| {
            for (list.items, 0..) |item, i| {
                if (item != sub) continue;
                _ = list.swapRemove(i);
                break;
            }
            if (list.items.len == 0) {
                const gone = hub.keys.fetchRemove(sub.key).?;
                hub.gpa.free(gone.key);
                var empty = gone.value;
                empty.deinit(hub.gpa);
            }
        }
        hub.generations.items[sub.id.index] +%= 1;
        hub.free.appendAssumeCapacity(sub.id.index);
        hub.count -= 1;
        break :last hub.closing and hub.count == 0;
    };
    // After the unlock: once `emptied` is set, the mutex may be gone too.
    if (last) hub.emptied.set(io);
}

/// Queues `bytes`, an event as the stream sends it, for every subscriber
/// of `key`, and returns at once: a subscriber whose queue it would take
/// over the limits is closed. No subscriber: nothing happens. Bytes longer
/// than `.queue.max_bytes` fit no queue: `error.EventTooLarge`, logged, and
/// the subscribers stay.
pub fn publish(hub: *Hub, io: std.Io, key: []const u8, bytes: []const u8) error{EventTooLarge}!void {
    if (bytes.len > hub.options.queue.max_bytes) {
        log.warn("publish: an SSE event of {d} bytes is longer than the .queue.max_bytes of its manager, {d}; it is sent to nobody", .{ bytes.len, hub.options.queue.max_bytes });
        return error.EventTooLarge;
    }
    hub.mutex.lockUncancelable(io);
    defer hub.mutex.unlock(io);
    const list = hub.keys.getPtr(key) orelse return;
    for (list.items) |sub| sub.push(io, bytes, hub.options.queue);
}

/// Ends every stream of `key`, as `Manager(Events).close` describes it.
pub fn close(hub: *Hub, io: std.Io, key: []const u8) void {
    hub.mutex.lockUncancelable(io);
    defer hub.mutex.unlock(io);
    const list = hub.keys.getPtr(key) orelse return;
    for (list.items) |sub| sub.end(io, .closed);
}
