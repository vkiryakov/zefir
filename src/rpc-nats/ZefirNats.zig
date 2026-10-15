//! The adapter of zefir-nats: `rpc_nats.Conn` on a `nats.Client`, so that
//! the NATS transport of rpc runs on the NATS client of zefir.
//!
//! ```zig
//! var nc: nats.Client = try .init(gpa, io, .{ .servers = &.{"nats://127.0.0.1:4222"} });
//! defer nc.deinit();
//! try nc.connect();
//! var adapter: rpc_nats.ZefirNats = .{ .client = &nc };
//! var bus: rpc_nats.Transport = try .init(gpa, adapter.conn(), .{});
//! defer bus.deinit(io); // before nc.deinit()
//! ```
//!
//! What it asks of the client:
//!
//! - The client runs on the `std.Io` of rpc. The transport passes its `io`
//!   to every operation, and in safe builds another one than the client's
//!   panics: canceling a task would not end a wait inside the client.
//! - `no_responders` stays on, as it is by default: then a call that no
//!   server takes fails at once with Unavailable instead of at its deadline.
//!   zefir-nats always asks for headers.
//! - The client outlives the transport: deinit the transport first. The
//!   adapter takes its memory from the client's allocator, and stays where
//!   it is once `conn()` has handed it out.
//! - One adapter serves one transport. A flush tells of a subscription the
//!   server refused that was made before it, whoever made it; the
//!   transport confirms the subscriptions of its server side and of its
//!   inbox one at a time, so the refusal reaches the side that made it.
//!   Two transports on one client take an adapter each.
//!
//! Every subscription of the transport, a route or the client's inbox,
//! holds `pending` messages: NATS drops what does not fit as a slow
//! consumer, and the adapter tells the transport, which counts and logs
//! the drops. `drain` of a subscription returns at once: the server
//! confirms its UNSUB in a task of the adapter, and then the transport
//! reads the rest and the end.
//!
//! What zefir-nats does otherwise than the transport could wish: the
//! server drops a publish its permissions deny and reports it with a
//! `-ERR`, which the client turns into an event, so a call to a route the
//! client may not publish to ends with Timeout, not AccessDenied. A
//! subscription the permissions deny fails the next flush, so the server
//! side's `start` and the client's first call see it as AccessDenied.

const std = @import("std");
const nats = @import("nats");
const rpc = @import("rpc");
const Conn = @import("Conn.zig");

const ZefirNats = @This();

const log = std.log.scoped(.rpc_nats);

/// The NATS client; it outlives the adapter.
client: *nats.Client,
/// The queue of each subscription the transport makes: the requests of a
/// route, or the responses of the client's inbox, that wait for the
/// transport to take them. NATS drops what does not fit, so it holds at
/// least the server's `max_inflight` messages (`rpc.Limits`), 4352 by
/// default. Null bytes: the client's `limits.subscription_bytes`.
pending: nats.SubscribeOptions.Pending = .{ .messages = default_pending_messages },
/// Internal: guards `unconfirmed` and `next_order`.
mutex: std.Io.Mutex = .init,
/// Internal: the subscriptions no flush has answered for yet, in the
/// order they were made.
unconfirmed: std.DoublyLinkedList = .{},
/// Internal: the order of the next subscription.
next_order: u64 = 0,

const default_limits: rpc.Limits = .{};

/// The `max_inflight` of a server with the default `rpc.Limits`.
pub const default_pending_messages: u32 = default_limits.max_active_tasks + default_limits.queue_capacity;

/// The interface, for `rpc_nats.Transport.init`.
pub fn conn(z: *ZefirNats) Conn {
    return .init(z);
}

/// One subscription of the transport.
const Sub = struct {
    sub: *nats.Subscription,
    /// Its place among the subscriptions: a flush that began later
    /// answers for it.
    order: u64,
    node: std.DoublyLinkedList.Node = .{},
    /// In `unconfirmed`.
    listed: bool = true,
    /// The drops `next` has told of; only the task in `next` touches it.
    dropped_seen: u64 = 0,
    /// The task that drains it, from `drain` until `unsubscribe`.
    drain_task: ?std.Io.Future(void) = null,
};

/// A message the transport holds until its `release`.
const Received = struct {
    msg: nats.Message,

    fn release(context: *anyopaque) void {
        const r: *Received = @ptrCast(@alignCast(context));
        var msg = r.msg;
        const gpa = msg.gpa;
        msg.deinit();
        gpa.destroy(r);
    }
};

comptime {
    // The headers of the transport go to the client as they are.
    std.debug.assert(@sizeOf(Conn.Header) == @sizeOf(nats.Header));
    std.debug.assert(@offsetOf(Conn.Header, "name") == @offsetOf(nats.Header, "name"));
    std.debug.assert(@offsetOf(Conn.Header, "value") == @offsetOf(nats.Header, "value"));
}

/// `rpc_nats.Conn.publish`: `nats.Client.publishMessageTimeout`.
pub fn publish(z: *ZefirNats, io: std.Io, msg: Conn.OutMsg, timeout: std.Io.Timeout) Conn.Error!void {
    z.checkIo(io);
    const headers: []const nats.Header = @ptrCast(msg.headers);
    z.client.publishMessageTimeout(.{ .subject = msg.subject, .reply_to = msg.reply_to, .headers = headers, .payload = msg.payload }, timeout) catch |err| return switch (err) {
        error.PayloadTooLarge => error.PayloadTooLarge,
        error.Timeout => error.Timeout,
        error.Canceled => error.Canceled,
        error.OutOfMemory => error.OutOfMemory,
        // Not connected yet, or reconnecting with the reconnect buffer full.
        error.Disconnected, error.BufferFull => error.Disconnected,
        // The client drains or has closed: no more publishes.
        error.ConnectionDraining, error.ConnectionClosed => error.ConnectionClosed,
        error.InvalidSubject, error.InvalidHeader, error.UnsupportedFeature, error.ProtocolError => refused("a publish to", msg.subject, err),
    };
}

/// `rpc_nats.Conn.subscribe`: `nats.Client.subscribe` with `pending`.
pub fn subscribe(z: *ZefirNats, io: std.Io, subject: []const u8, queue: ?[]const u8, timeout: std.Io.Timeout) Conn.Error!Conn.Sub {
    z.checkIo(io);
    const gpa = z.client.gpa;
    const box = box: {
        // A Debug allocator may take a cancelable lock.
        const protection = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(protection);
        break :box try gpa.create(Sub);
    };
    errdefer {
        const protection = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(protection);
        gpa.destroy(box);
    }
    const sub = z.client.subscribe(subject, .{ .queue = queue, .pending = z.pending, .timeout = timeout }) catch |err| return switch (err) {
        error.Disconnected => error.Disconnected,
        error.ConnectionDraining, error.ConnectionClosed => error.ConnectionClosed,
        // No room in the client's outbound queue for the SUB in time.
        error.Timeout => error.Timeout,
        error.Canceled => error.Canceled,
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidSubject, error.InvalidOptions, error.TooManySubscriptions, error.ProtocolError => refused("a subscription to", subject, err),
    };
    // After its SUB is queued: a flush that begins from now on answers
    // for it.
    z.mutex.lockUncancelable(io);
    defer z.mutex.unlock(io);
    box.* = .{ .sub = sub, .order = z.next_order };
    z.next_order += 1;
    z.unconfirmed.append(&box.node);
    return box;
}

/// zefir-nats refused what the transport asked: a bug of the transport, or
/// a client that cannot do it, such as a server without headers.
fn refused(comptime what: []const u8, subject: []const u8, err: anyerror) error{InvalidSubject} {
    log.warn("zefir-nats refused " ++ what ++ " {s}: {t}", .{ subject, err });
    return error.InvalidSubject;
}

/// `rpc_nats.Conn.next`: the next message of the subscription; first a
/// SlowConsumer when it has dropped messages since the last call.
pub fn next(z: *ZefirNats, io: std.Io, handle: Conn.Sub, timeout: std.Io.Timeout) Conn.Error!?Conn.InMsg {
    z.checkIo(io);
    const box: *Sub = @ptrCast(@alignCast(handle));
    const dropped = box.sub.stats().dropped;
    if (dropped != box.dropped_seen) {
        box.dropped_seen = dropped;
        return error.SlowConsumer;
    }
    const next_msg = box.sub.next(.{ .timeout = timeout }) catch |err| return switch (err) {
        error.Timeout => error.Timeout,
        error.Canceled => error.Canceled,
        error.PermissionDenied => error.PermissionDenied,
        error.ConnectionClosed => error.ConnectionClosed,
        // Only under `.close_subscription`, which the adapter never sets.
        error.SlowConsumer => error.SlowConsumer,
        error.ConcurrentReceive => @panic("rpc_nats.ZefirNats: two tasks wait in next of one subscription; one at a time"),
    };
    const msg = next_msg orelse return null;
    return try received(io, msg);
}

/// `msg` as the transport holds it, in a box of the client's allocator;
/// without memory for the box, the message is dropped.
fn received(io: std.Io, msg: nats.Message) error{OutOfMemory}!Conn.InMsg {
    var owned = msg;
    const r = r: {
        const protection = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(protection);
        break :r msg.gpa.create(Received) catch {
            owned.deinit();
            return error.OutOfMemory;
        };
    };
    r.* = .{ .msg = msg };
    return .{
        .subject = msg.subject,
        .reply_to = msg.reply_to,
        .header_block = msg.headers.block,
        .payload = msg.payload,
        .context = r,
        .release_fn = Received.release,
    };
}

/// `rpc_nats.Conn.drain`: a task of the adapter tells the server to stop
/// sending and waits for its confirmation; then `next` hands out what came
/// and null. It returns at once; a second call adds nothing.
pub fn drain(z: *ZefirNats, io: std.Io, handle: Conn.Sub) Conn.Error!void {
    z.checkIo(io);
    const box: *Sub = @ptrCast(@alignCast(handle));
    if (box.drain_task != null) return;
    box.drain_task = io.concurrent(drainTask, .{box.sub}) catch {
        // No task for it: drain here, as long as the reader needs, within
        // a bound.
        box.sub.drain(.{ .timeout = .{ .duration = .{ .raw = sync_drain_limit, .clock = .awake } } }) catch |err| return switch (err) {
            error.Timeout => error.Timeout,
            error.Canceled => error.Canceled,
            error.ConnectionClosed => error.ConnectionClosed,
            error.OutOfMemory => error.OutOfMemory,
        };
        return;
    };
}

/// How long `drain` waits when it has to drain in the caller's task.
const sync_drain_limit: std.Io.Duration = .fromSeconds(2);

/// Drains `sub`: the server confirms the UNSUB, the reader takes the rest.
/// `unsubscribe` cancels it.
fn drainTask(sub: *nats.Subscription) void {
    sub.drain(.{}) catch |err| switch (err) {
        error.Canceled => {},
        else => log.debug("the drain of {s} ended: {t}", .{ sub.subject, err }),
    };
}

/// `rpc_nats.Conn.unsubscribe`: ends the subscription and frees it.
pub fn unsubscribe(z: *ZefirNats, io: std.Io, handle: Conn.Sub) void {
    z.checkIo(io);
    const box: *Sub = @ptrCast(@alignCast(handle));
    // A Debug allocator may take a cancelable lock.
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    if (box.drain_task) |*task| task.cancel(io);
    {
        z.mutex.lockUncancelable(io);
        defer z.mutex.unlock(io);
        if (box.listed) z.unconfirmed.remove(&box.node);
    }
    box.sub.deinit();
    z.client.gpa.destroy(box);
}

/// `rpc_nats.Conn.flush`: `nats.Client.flush`, then PermissionDenied when
/// the server refused a subscription made before the flush began. Each
/// refusal fails one flush: the first that answers for it.
pub fn flush(z: *ZefirNats, io: std.Io, timeout: std.Io.Timeout) Conn.Error!void {
    z.checkIo(io);
    const horizon = horizon: {
        z.mutex.lockUncancelable(io);
        defer z.mutex.unlock(io);
        break :horizon z.next_order;
    };
    z.client.flush(.{ .timeout = timeout }) catch |err| return switch (err) {
        error.Disconnected => error.Disconnected,
        error.ConnectionClosed => error.ConnectionClosed,
        error.Timeout => error.Timeout,
        error.Canceled => error.Canceled,
        error.OutOfMemory => error.OutOfMemory,
    };
    // The server answers a SUB before the PONG of a later PING.
    if (z.answered(io, horizon)) return error.PermissionDenied;
}

/// Takes the subscriptions made before `horizon` out of `unconfirmed`;
/// true when the server refused one of them.
fn answered(z: *ZefirNats, io: std.Io, horizon: u64) bool {
    z.mutex.lockUncancelable(io);
    defer z.mutex.unlock(io);
    var denied = false;
    while (z.unconfirmed.first) |node| {
        const box: *Sub = @fieldParentPtr("node", node);
        if (box.order >= horizon) break;
        z.unconfirmed.remove(node);
        box.listed = false;
        if (box.sub.isDenied()) denied = true;
    }
    return denied;
}

/// `rpc_nats.Conn.isConnected`: the client has a connection now.
pub fn isConnected(z: *ZefirNats) bool {
    return z.client.isConnected();
}

/// In safe builds, panics when `io` is not the client's.
fn checkIo(z: *ZefirNats, io: std.Io) void {
    if (!std.debug.runtime_safety) return;
    const own = z.client.io;
    if (io.vtable != own.vtable or io.userdata != own.userdata)
        @panic("rpc_nats.ZefirNats: the transport runs on another std.Io than the nats.Client; give both the same one");
}

const testing = std.testing;
const Transport = @import("Transport.zig");

/// A server that refuses connections at once: nothing listens on port 1.
const nowhere: []const []const u8 = &.{"nats://127.0.0.1:1"};

fn within(duration: std.Io.Duration) std.Io.Timeout {
    return .{ .duration = .{ .raw = duration, .clock = .awake } };
}

test "before connect, publish, subscribe and flush are Disconnected; after close, ConnectionClosed" {
    const io = testing.io;
    var nc: nats.Client = try .init(testing.allocator, io, .{ .servers = nowhere });
    defer nc.deinit();
    var adapter: ZefirNats = .{ .client = &nc };
    const c = adapter.conn();
    try testing.expect(!c.isConnected());
    try testing.expectError(error.Disconnected, c.publish(io, .{ .subject = "users.v1.getUser", .reply_to = "_INBOX.x.1" }, within(.fromSeconds(1))));
    try testing.expectError(error.Disconnected, c.subscribe(io, "users.v1.getUser", "q", .none));
    try testing.expectError(error.Disconnected, c.flush(io, within(.fromSeconds(1))));
    nc.close();
    try testing.expectError(error.ConnectionClosed, c.publish(io, .{ .subject = "users.v1.getUser" }, .none));
    try testing.expectError(error.ConnectionClosed, c.subscribe(io, "users.v1.getUser", null, .none));
    try testing.expectError(error.ConnectionClosed, c.flush(io, .none));
    // Arguments the client refuses: a warning and InvalidSubject.
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;
    try testing.expectError(error.InvalidSubject, c.publish(io, .{ .subject = "two words" }, .none));
    try testing.expectError(error.InvalidSubject, c.subscribe(io, "users.v1.getUser", "two words", .none));
    try testing.expectEqual(@as(usize, 0), adapter.unconfirmed.len());
}

test "while the client reconnects: subscriptions wait, drain ends them, unsubscribe frees them" {
    const io = testing.io;
    // The client keeps trying, and warns of every attempt.
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;
    var nc: nats.Client = try .init(testing.allocator, io, .{ .servers = nowhere, .retry_initial_connect = true });
    defer nc.deinit();
    try nc.connect();
    var adapter: ZefirNats = .{ .client = &nc };
    const c = adapter.conn();
    try testing.expect(!c.isConnected());
    // A SUB goes out with the next connection; a flush needs one now, and
    // answers for nothing meanwhile.
    const routes = try c.subscribe(io, "users.v1.getUser", "q", .none);
    const inbox = try c.subscribe(io, "_INBOX.token.*", null, .none);
    try testing.expectEqual(@as(usize, 2), adapter.unconfirmed.len());
    // The timeout of a subscription is the client's too: one already over
    // subscribes nothing.
    try testing.expectError(error.Timeout, c.subscribe(io, "orders.v1.place", "q", within(.zero)));
    try testing.expectEqual(@as(usize, 2), adapter.unconfirmed.len());
    try testing.expectError(error.Disconnected, c.flush(io, within(.fromSeconds(1))));
    try testing.expectEqual(@as(usize, 2), adapter.unconfirmed.len());
    try testing.expectError(error.Timeout, c.next(io, routes, within(.fromMilliseconds(20))));
    // Without a connection nothing more can come: the drain ends at once.
    try c.drain(io, routes);
    try c.drain(io, routes);
    try testing.expectEqual(@as(?Conn.InMsg, null), try c.next(io, routes, within(.fromSeconds(5))));
    c.unsubscribe(io, routes);
    c.unsubscribe(io, inbox);
    try testing.expectEqual(@as(usize, 0), adapter.unconfirmed.len());
    // A publish waits in the reconnect buffer; the client drops it at its
    // close.
    try c.publish(io, .{ .subject = "orders.v1.place", .payload = "x" }, within(.fromSeconds(1)));
}

test "the transport on a client without a connection: start and calls are Unavailable" {
    const io = testing.io;
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;
    var nc: nats.Client = try .init(testing.allocator, io, .{ .servers = nowhere, .retry_initial_connect = true });
    defer nc.deinit();
    try nc.connect();
    var adapter: ZefirNats = .{ .client = &nc };
    var bus: Transport = try .init(testing.allocator, adapter.conn(), .{ .flush_timeout = .fromMilliseconds(200) });
    defer bus.deinit(io);
    try testing.expect(!bus.isReady());

    const Echo = struct {
        fn handle(ptr: *anyopaque, ctx: *rpc.Context, request: []const u8) anyerror![]const u8 {
            _ = ptr;
            _ = ctx;
            return request;
        }
    };
    var state: u8 = 0;
    const methods = [_]rpc.Method{.{ .route = .{ .service = "users", .version = 1, .method = "getUser" }, .handler = .{ .ptr = &state, .handle = Echo.handle } }};
    var server: rpc.RawServer = try .init(testing.allocator, .{ .transport = bus.serverTransport(), .methods = &methods });
    defer server.deinit(io);
    try testing.expectError(error.Unavailable, server.start(io));
    // The failed start left no subscription behind.
    try testing.expectEqual(@as(usize, 0), adapter.unconfirmed.len());

    var client: rpc.RawClient = try .init(testing.allocator, .{ .transport = bus.clientTransport() });
    defer client.deinit();
    try testing.expectError(error.Unavailable, client.call(io, .root, .{ .service = "users", .version = 1, .method = "getUser" }, "{}", .{}));
}

test "a message is the transport's until its release, and the release frees it" {
    const gpa = testing.allocator;
    const block = "NATS/1.0\r\nZefir-Rpc-Version: 1\r\n\r\n";
    const parts = [_][]const u8{ "users.v1.getUser", "_INBOX.t.7", block, "{\"id\":\"1\"}" };
    var len: usize = 0;
    for (parts) |part| len += part.len;
    const buffer = try gpa.alloc(u8, len);
    var slices: [parts.len][]const u8 = undefined;
    var at: usize = 0;
    for (parts, &slices) |part, *slice| {
        @memcpy(buffer[at..][0..part.len], part);
        slice.* = buffer[at..][0..part.len];
        at += part.len;
    }
    const msg: nats.Message = .{
        .subject = slices[0],
        .reply_to = slices[1],
        .headers = .{ .block = slices[2] },
        .payload = slices[3],
        .status = null,
        .description = "",
        .buffer = buffer,
        .gpa = gpa,
    };
    const in = try received(testing.io, msg);
    try testing.expectEqualStrings("users.v1.getUser", in.subject);
    try testing.expectEqualStrings("_INBOX.t.7", in.reply_to.?);
    try testing.expectEqualStrings(block, in.header_block);
    try testing.expectEqualStrings("{\"id\":\"1\"}", in.payload);
    // From another task, as the engine may release it.
    var task = try testing.io.concurrent(Conn.InMsg.release, .{in});
    task.await(testing.io);
}
