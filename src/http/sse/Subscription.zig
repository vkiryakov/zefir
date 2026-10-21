//! One subscription of an `http.sse.Manager`, kept by
//! its hub: the stream of one request, from its `subscribe` to its end. It owns what the
//! stream lives on: the connection, which the server hands over and keeps
//! for it to the end, an arena, a copy of its key and a `core.Context` of
//! its own (its own token, a copy of the request's trace, no deadline).
//!
//! Two tasks serve a stream, beside the connection's task, which waits for
//! its end: the writer sends what publishers queue, and the heartbeat when
//! nothing went out for its interval; the watcher reads the connection and
//! sees the client leave. A publisher never waits: it puts the bytes of its
//! event in the queue and wakes the writer. A queue over its limits ends
//! the stream, so a client that falls behind costs no more memory than the
//! limits. Internal to the module.
const std = @import("std");
const core = @import("core");
const Exchange = @import("../Backend.zig").Exchange;
const HttpContext = @import("../Context.zig");
const format = @import("format.zig");
const waiting = @import("../wait.zig");
const Hub = @import("Hub.zig");

const Subscription = @This();
const log = std.log.scoped(.http);

hub: *Hub,
/// The hub's allocator, copied: the queue comes from it, and the end of
/// the stream frees it without touching the hub, which may be gone once
/// `remove` has let the subscription go.
gpa: std.mem.Allocator,
/// Its place in the hub, set when the hub takes it.
id: Hub.SubscriptionId = .{ .index = 0, .generation = 0 },
/// The key it was subscribed under, copied.
key: []const u8,
/// The id of the request that opened it, copied, for the log.
request_id: []const u8,
/// The memory of the subscription: itself, its key, its trace.
arena: std.heap.ArenaAllocator,
/// Its own token: canceled once the stream has ended and its `on_close`
/// has run.
token: core.CancellationToken = .init,
/// Its context: the trace of the request that opened it and `token`.
operation: core.Context = .root,
/// Guards `queue`, `queued` and `end_reason`; never held across I/O.
mutex: std.Io.Mutex = .init,
/// The bytes of the events that publishers queued and the writer has not
/// taken yet, from the manager's allocator, and how many events they are.
queue: std.ArrayList(u8) = .empty,
queued: u32 = 0,
/// Why the stream ends; `open` until it is decided, once.
end_reason: End = .open,
/// Set once the end is decided: the connection's task ends the stream.
ended: std.Io.Event = .unset,
/// Set when events are queued, and when the end is decided: the writer
/// wakes.
wake: std.Io.Event = .unset,
/// Set when the writer has returned, however it did.
writer_done: std.Io.Event = .unset,
/// A write of the stream failed or was cut: its response cannot end
/// whole. Written by the writer, read after it has ended.
broken: bool = false,
/// Its place in the server's list of open streams, which the stop closes.
node: std.DoublyLinkedList.Node = .{},
/// In the server's list.
listed: bool = false,

/// Why a stream ends.
pub const End = enum(u8) {
    open,
    /// The client left: the watcher saw the end of the connection.
    client_gone,
    /// A write failed: the client did not read within the backend's write
    /// timeout, or the connection broke.
    write_failed,
    /// `close(key)`, or the manager's `deinit`.
    closed,
    /// The queue went over its limits: the client fell behind.
    overflow,
    /// The server stopped and closed its streams.
    shutdown,
    /// The request that subscribed did not end well (its handler failed
    /// after `subscribe`, its deadline passed, its client left or the stop
    /// canceled it), or the runtime gave the stream no task.
    failed,
};

/// A subscription of `hub` for the request of `ctx` under `key`, not
/// taken by the hub yet.
pub fn create(hub: *Hub, ctx: *const HttpContext, key: []const u8) error{OutOfMemory}!*Subscription {
    var arena: std.heap.ArenaAllocator = .init(hub.gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const sub = try a.create(Subscription);
    var operation: core.Context = .root;
    if (ctx.operation().trace) |trace| {
        // The bytes of the trace's state live in the request's memory.
        var copy = trace;
        copy.state.header = try a.dupe(u8, trace.state.header);
        operation = operation.withTrace(copy);
    }
    sub.* = .{
        .hub = hub,
        .gpa = hub.gpa,
        .key = try a.dupe(u8, key),
        .request_id = try a.dupe(u8, ctx.requestId()),
        .arena = undefined,
    };
    sub.operation = operation.withCancellation(&sub.token);
    // No allocation from here on: the arena moves into the subscription.
    sub.arena = arena;
    return sub;
}

/// Frees the subscription, once its stream has ended and the hub has let
/// it go.
pub fn destroy(sub: *Subscription) void {
    sub.queue.deinit(sub.gpa);
    // The subscription lives in its arena: the arena goes by value.
    sub.arena.deinit();
}

/// Decides the end of the stream, unless it is decided already: the
/// connection's task wakes and ends it, and so does the writer, which
/// sends what is queued first when the server closes the stream. Never
/// waits.
pub fn end(sub: *Subscription, io: std.Io, why: End) void {
    const first = first: {
        sub.mutex.lockUncancelable(io);
        defer sub.mutex.unlock(io);
        if (sub.end_reason != .open) break :first false;
        sub.end_reason = why;
        break :first true;
    };
    if (!first) return;
    sub.ended.set(io);
    sub.wake.set(io);
}

/// Whether the stream ends whole: the server closed it (`close(key)`, the
/// stop), so what was published before goes out, then the end of the
/// response. Every other end cuts it at once.
pub fn endsWhole(why: End) bool {
    return why == .closed or why == .shutdown;
}

/// Why the stream ends; `open` while it is open.
pub fn endReason(sub: *Subscription, io: std.Io) End {
    sub.mutex.lockUncancelable(io);
    defer sub.mutex.unlock(io);
    return sub.end_reason;
}

/// Queues the bytes of an event, unless the stream has ended; never
/// waits. An event that would take the queue over `limits` ends the stream
/// instead (`.overflow = .close`), and so does a queue that cannot grow.
pub fn push(sub: *Subscription, io: std.Io, bytes: []const u8, limits: Hub.Options.Queue) void {
    const Pushed = enum { queued, dropped, overflow, out_of_memory };
    const pushed: Pushed = pushed: {
        sub.mutex.lockUncancelable(io);
        defer sub.mutex.unlock(io);
        if (sub.end_reason != .open) break :pushed .dropped;
        if (sub.queued >= limits.max_events or sub.queue.items.len + bytes.len > limits.max_bytes) {
            sub.end_reason = .overflow;
            break :pushed .overflow;
        }
        sub.queue.appendSlice(sub.gpa, bytes) catch {
            sub.end_reason = .overflow;
            break :pushed .out_of_memory;
        };
        sub.queued += 1;
        break :pushed .queued;
    };
    switch (pushed) {
        .queued => sub.wake.set(io),
        .dropped => {},
        .overflow => {
            log.warn("the client of an SSE stream fell behind: its queue is over {d} events or {d} bytes; the stream is closed (request {s})", .{ limits.max_events, limits.max_bytes, sub.request_id });
            sub.ended.set(io);
        },
        .out_of_memory => {
            log.warn("out of memory for the queue of an SSE stream; the stream is closed (request {s})", .{sub.request_id});
            sub.ended.set(io);
        },
    }
}

/// The writer of the stream, on a task of its own: sends what publishers
/// queue, all of it at once, and `: ping` when nothing went out for
/// `heartbeat`. When the server closes the stream, it sends what was queued
/// before and returns; every other end cancels it. A write that fails ends
/// the stream.
pub fn writer(sub: *Subscription, io: std.Io, exchange: *Exchange, heartbeat: ?std.Io.Duration) void {
    defer sub.writer_done.set(io);
    const gpa = sub.gpa;
    // The queue and this batch trade places: the writer sends one while
    // publishers fill the other.
    var batch: std.ArrayList(u8) = .empty;
    defer batch.deinit(gpa);
    var last = std.Io.Clock.awake.now(io);
    while (true) {
        // Before the queue is looked at: a publisher that queues after it
        // sets the event again.
        sub.wake.reset();
        const closing = closing: {
            sub.mutex.lockUncancelable(io);
            defer sub.mutex.unlock(io);
            std.mem.swap(std.ArrayList(u8), &sub.queue, &batch);
            sub.queued = 0;
            break :closing endsWhole(sub.end_reason);
        };
        if (batch.items.len > 0) {
            if (!sub.send(io, exchange, batch.items)) return;
            batch.clearRetainingCapacity();
            last = std.Io.Clock.awake.now(io);
            continue;
        }
        // Closed, and what was published before has gone out.
        if (closing) return;
        const every = heartbeat orelse {
            sub.wake.wait(io) catch return;
            continue;
        };
        waiting.untilSet(&sub.wake, io, .after(last, every)) catch |err| switch (err) {
            error.Canceled => return,
            error.Timeout => {
                if (!sub.send(io, exchange, format.heartbeat)) return;
                last = std.Io.Clock.awake.now(io);
            },
        };
    }
}

/// Sends `bytes` at once; false when the write failed, which ends the
/// stream.
fn send(sub: *Subscription, io: std.Io, exchange: *Exchange, bytes: []const u8) bool {
    exchange.writeBody(io, bytes) catch return sub.fail(io);
    exchange.flush(io) catch return sub.fail(io);
    return true;
}

fn fail(sub: *Subscription, io: std.Io) bool {
    sub.broken = true;
    sub.end(io, .write_failed);
    return false;
}

/// The watcher of the stream, on a task of its own until the connection's
/// task cancels it: reads the connection, without a deadline, and ends the
/// stream when the client leaves. What it reads stays in the connection's
/// buffer.
pub fn watcher(sub: *Subscription, io: std.Io, exchange: *Exchange) void {
    exchange.watch(io);
    // The client left, unless the watch was canceled at the end of the
    // stream: the end is decided by then, and this changes nothing.
    sub.end(io, .client_gone);
}
