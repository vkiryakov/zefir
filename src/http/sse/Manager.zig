//! `http.sse.Manager` (design section 12): the subscriptions of this
//! process to SSE streams, by key. A controller keeps a pointer to one;
//! the route's handler subscribes the request under a key, such as the id
//! of its user, and any task publishes to every subscriber of a key.
//!
//! ```zig
//! var live: http.sse.Manager = .init(gpa, .{});
//! defer live.deinit(io);
//!
//! // The handler of an `http.sse.get` route:
//! pub fn events(self: *TodosV1Controller, ctx: *http.sse.Context) !void {
//!     _ = try self.live.subscribe(ctx, owner(ctx)); // returns at once; the stream lives on
//! }
//!
//! // Anywhere else, in the publisher's own context:
//! try self.live.publish(ctx.operation(), ctx.io(), owner(ctx), .{ .event = "todo.created", .data = dto.TodoResponse.from(todo) });
//! ```
//!
//! A publisher never waits for delivery: the event goes into the queue of
//! each subscriber, and a subscriber whose queue goes over its limits
//! (`.queue`) is closed, so a client that falls behind costs no more
//! memory than the limits. The manager is thread-safe: zio runs the
//! streams and the publishers on several threads.
const std = @import("std");
const core = @import("core");
const v = @import("validator");
const HttpContext = @import("../Context.zig");
const sse = @import("../sse.zig");
const flow = @import("../flow.zig");
const json_out = @import("../output/json_out.zig");
const format = @import("format.zig");
const Subscription = @import("Subscription.zig");

const Manager = @This();
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

/// The limits of a manager (design section 15).
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

pub fn init(gpa: std.mem.Allocator, options: Options) Manager {
    return .{ .gpa = gpa, .options = options };
}

/// Closes the streams still open, as `close` does, waits until they have
/// ended and their `.on_close` has run, and frees the manager. Usually
/// after the server's `deinit`, when none is open; an `.on_close` may still
/// publish through it meanwhile.
pub fn deinit(m: *Manager, io: std.Io) void {
    const open = open: {
        m.mutex.lockUncancelable(io);
        defer m.mutex.unlock(io);
        m.closing = true;
        var lists = m.keys.valueIterator();
        while (lists.next()) |list| {
            for (list.items) |sub| sub.end(io, .closed);
        }
        break :open m.count;
    };
    // Each stream leaves the manager as it ends.
    if (open > 0) m.emptied.waitUncancelable(io);
    m.keys.deinit(m.gpa);
    m.generations.deinit(m.gpa);
    m.free.deinit(m.gpa);
    m.* = undefined;
}

/// Opens the stream of the request under `key` and returns at once; the
/// stream lives on until the client leaves, `close(key)`, its queue
/// overflows or the server stops, and then the route's `.on_close` runs.
/// It sends the head of the stream: 200, `Content-Type:
/// text/event-stream`, `Cache-Control: no-cache` and `X-Accel-Buffering:
/// no`, with the fields the middleware set. From here on the request is
/// counted among the server's streams, not in `.max_in_flight`, and its
/// deadline no longer applies. The key is copied.
pub fn subscribe(m: *Manager, ctx: *sse.Context, key: []const u8) SubscribeError!SubscriptionId {
    const http_ctx = ctx.internal.http;
    const io = http_ctx.io();
    if (ctx.internal.phase != .opening or http_ctx.internal.subscription != null) {
        log.warn("subscribe: the stream of this request is open already, or it has ended (request {s})", .{http_ctx.requestId()});
        return error.WriteFailed;
    }
    const server = http_ctx.internal.server orelse return error.WriteFailed;
    if (!flow.takeStream(server)) return error.Overloaded;
    errdefer flow.releaseStream(server, io);
    const sub = try Subscription.create(m, http_ctx, key);
    errdefer sub.destroy();
    try m.add(io, sub);
    errdefer m.remove(io, sub);
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

/// Takes `sub` under its key, unless the manager is full or closing.
fn add(m: *Manager, io: std.Io, sub: *Subscription) SubscribeError!void {
    m.mutex.lockUncancelable(io);
    defer m.mutex.unlock(io);
    if (m.closing or m.count >= m.options.max_subscriptions) return error.Overloaded;
    // The memory for a new place first: past `addToKey` nothing fails.
    try m.generations.ensureUnusedCapacity(m.gpa, 1);
    try m.free.ensureTotalCapacity(m.gpa, m.generations.items.len + 1);
    try m.addToKey(sub);
    const index: u32 = m.free.pop() orelse new: {
        m.generations.appendAssumeCapacity(0);
        break :new @intCast(m.generations.items.len - 1);
    };
    sub.id = .{ .index = index, .generation = m.generations.items[index] };
    m.count += 1;
}

fn addToKey(m: *Manager, sub: *Subscription) error{OutOfMemory}!void {
    const entry = try m.keys.getOrPut(m.gpa, sub.key);
    if (entry.found_existing) return entry.value_ptr.append(m.gpa, sub);
    // A new key: the manager keeps a copy of its own, which outlives the
    // subscription.
    const owned = m.gpa.dupe(u8, sub.key) catch |err| {
        m.keys.removeByPtr(entry.key_ptr);
        return err;
    };
    entry.key_ptr.* = owned;
    entry.value_ptr.* = .empty;
    entry.value_ptr.append(m.gpa, sub) catch |err| {
        m.keys.removeByPtr(entry.key_ptr);
        m.gpa.free(owned);
        return err;
    };
}

/// Lets `sub` go, once its stream has ended and its `.on_close` has run:
/// publishers no longer reach it, and its place is free with a new
/// generation. The last one after `deinit` has begun wakes it, as the last
/// touch of the manager: `deinit` may free the manager from then on.
pub fn remove(m: *Manager, io: std.Io, sub: *Subscription) void {
    const last = last: {
        m.mutex.lockUncancelable(io);
        defer m.mutex.unlock(io);
        if (m.keys.getPtr(sub.key)) |list| {
            for (list.items, 0..) |item, i| {
                if (item != sub) continue;
                _ = list.swapRemove(i);
                break;
            }
            if (list.items.len == 0) {
                const gone = m.keys.fetchRemove(sub.key).?;
                m.gpa.free(gone.key);
                var empty = gone.value;
                empty.deinit(m.gpa);
            }
        }
        m.generations.items[sub.id.index] +%= 1;
        m.free.appendAssumeCapacity(sub.id.index);
        m.count -= 1;
        break :last m.closing and m.count == 0;
    };
    // After the unlock: once `emptied` is set, the mutex may be gone too.
    if (last) m.emptied.set(io);
}

/// Sends `event` to every subscriber of `key`, in the publisher's own
/// context, and returns at once: each gets it in its queue, and a
/// subscriber whose queue it would take over the limits is closed. No
/// subscriber: nothing happens.
///
/// `event` is a struct literal: `.data`, the value sent as JSON, through
/// its transforms and by the outside names of its `field_rules`, as
/// `http.Json(T)` writes it; and optionally `.event` (the type of the
/// event, a string), `.id` (a string the client sends back as
/// `Last-Event-ID` when it reconnects) and `.retry` (milliseconds the
/// client waits before it reconnects):
///
/// ```zig
/// try live.publish(ctx.operation(), ctx.io(), key, .{ .event = "todo.created", .id = "42", .data = todo });
/// ```
///
/// `error.InvalidEvent` (500): CR, LF or NUL in `.event` or `.id`.
/// `error.EventTooLarge` (500, logged): the event, as the stream sends it,
/// is longer than `.queue.max_bytes`, so no queue could hold it; it goes to
/// nobody, and the subscribers stay. An error of a transform of the data
/// comes back as it is, as `v.TransformError(T)` says. `op` is the
/// publisher's: publishing never waits, so its deadline and token do not
/// stop it.
pub fn publish(m: *Manager, op: core.Context, io: std.Io, key: []const u8, event: anytype) PublishError(@TypeOf(event))!void {
    _ = op;
    const E = @TypeOf(event);
    const name = stringOf(event, "event");
    const id = stringOf(event, "id");
    if (name) |text| if (!format.validField(text)) return error.InvalidEvent;
    if (id) |text| if (!format.validField(text)) return error.InvalidEvent;
    const retry: ?u64 = if (@hasField(E, "retry")) event.retry else null;
    var arena: std.heap.ArenaAllocator = .init(m.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const data = try json_out.encode(a, event.data, .{});
    const bytes = try format.alloc(a, .{ .event = name, .id = id, .retry = retry, .data = data });
    if (bytes.len > m.options.queue.max_bytes) {
        log.warn("publish: an SSE event of {d} bytes is longer than the .queue.max_bytes of its manager, {d}; it is sent to nobody", .{ bytes.len, m.options.queue.max_bytes });
        return error.EventTooLarge;
    }
    m.mutex.lockUncancelable(io);
    defer m.mutex.unlock(io);
    const list = m.keys.getPtr(key) orelse return;
    for (list.items) |sub| sub.push(io, bytes, m.options.queue);
}

/// Ends every stream of `key`, such as when its user signs out: what was
/// published to it before goes out, then the end of the response, and its
/// `.on_close` runs; what is published after is not sent. A client may
/// connect again.
pub fn close(m: *Manager, io: std.Io, key: []const u8) void {
    m.mutex.lockUncancelable(io);
    defer m.mutex.unlock(io);
    const list = m.keys.getPtr(key) orelse return;
    for (list.items) |sub| sub.end(io, .closed);
}

/// The errors of `publish` for an event of type `E`, which is checked at
/// compile time first.
fn PublishError(comptime E: type) type {
    comptime checkEvent(E);
    return error{ InvalidEvent, EventTooLarge } || v.TransformError(@FieldType(E, "data"));
}

fn checkEvent(comptime E: type) void {
    const where = "zefir.http: http.sse.Manager.publish: ";
    const info = @typeInfo(E);
    if (info != .@"struct" or info.@"struct".is_tuple) @compileError(where ++ "the event is a struct literal, such as .{ .event = \"todo.created\", .data = value }");
    for (info.@"struct".field_names) |name| {
        for ([_][]const u8{ "event", "data", "id", "retry" }) |known| {
            if (std.mem.eql(u8, name, known)) break;
        } else @compileError(where ++ "the event has no field ." ++ name ++ "; its fields are .event, .data, .id and .retry");
    }
    if (!@hasField(E, "data")) @compileError(where ++ "the event needs .data, the value it sends as JSON");
    for ([_][]const u8{ "event", "id" }) |name| {
        if (@hasField(E, name) and !isString(@FieldType(E, name)))
            @compileError(where ++ "." ++ name ++ " is a string, such as \"todo.created\", or null");
    }
    if (@hasField(E, "retry") and !isMilliseconds(@FieldType(E, "retry")))
        @compileError(where ++ ".retry is a number of milliseconds, an unsigned integer such as 3000, or null");
}

/// Whether a value of `T` coerces to `?[]const u8`.
fn isString(comptime T: type) bool {
    if (T == @TypeOf(null)) return true;
    const info = @typeInfo(T);
    if (info == .optional) return isString(info.optional.child);
    if (info != .pointer) return false;
    const p = info.pointer;
    return switch (p.size) {
        .slice => p.child == u8,
        .one => @typeInfo(p.child) == .array and @typeInfo(p.child).array.child == u8,
        else => false,
    };
}

/// Whether a value of `T` coerces to `?u64`.
fn isMilliseconds(comptime T: type) bool {
    if (T == @TypeOf(null) or T == comptime_int) return true;
    const info = @typeInfo(T);
    if (info == .optional) return isMilliseconds(info.optional.child);
    return info == .int and info.int.signedness == .unsigned and info.int.bits <= 64;
}

fn stringOf(event: anytype, comptime name: []const u8) ?[]const u8 {
    if (!@hasField(@TypeOf(event), name)) return null;
    return @field(event, name);
}
