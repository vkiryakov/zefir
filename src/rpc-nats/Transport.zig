//! The NATS transport of rpc: one object for both sides, on one NATS
//! connection that the application owns. The server engine gets
//! `serverTransport()`, its clients get `clientTransport()`.
//!
//! ```zig
//! var bus: rpc_nats.Transport = try .init(gpa, adapter.conn(), .{});
//! defer bus.deinit(io); // after the server's deinit and the last call
//! var server: rpc.Server = try .init(gpa, .{ .transport = bus.serverTransport(), .handlers = .{&users} });
//! ```
//!
//! The server subscribes to the subject of every route in the queue group
//! `queue_group`, so the replicas of a service share its requests, and
//! confirms the subscriptions with a flush: a subject the NATS permissions
//! deny fails `start` with AccessDenied. It answers only to a reply subject
//! under `reply_prefixes`, and only to a request with one. A request from
//! `nats req`, without the headers of zefir, is served too.
//!
//! What the server side does with the errors of the connection:
//!
//! | Where | Error | Action |
//! |---|---|---|
//! | `start` | PermissionDenied | `error.AccessDenied` |
//! | `start` | Disconnected, ConnectionClosed, Timeout | `error.Unavailable` |
//! | receiving | SlowConsumer | counted and logged; it goes on |
//! | receiving | PermissionDenied, ConnectionClosed | `Dispatcher.fail`: the server stops |
//! | receiving | Disconnected | it waits on; `isReady` is false meanwhile |
//! | `Reply.send` | PayloadTooLarge / Disconnected, ConnectionClosed / other | ResponseTooLarge / Closed / Unexpected |
//!
//! NATS has no signal that a client gave up, so a handler runs until its
//! own deadline, and `info().propagates_cancellation` is false. `close`
//! returns within `flush_timeout`, the bound of its flush, plus the time a
//! receiving task needs to hand over the request it holds.
//!
//! The client publishes a request only while the link is up: a request
//! buffered in the library during a reconnect would reach the server with
//! a stale budget. The budget left goes in `Zefir-Rpc-Timeout-Ms`, measured
//! right before publish. All calls share one inbox subscription, started by
//! the first call; a call that waits through a reconnect may still get its
//! response before its deadline.
//!
//! | On the wire | `call` returns |
//! |---|---|
//! | a reply without `Nats-Service-Error` and without a status line | `.ok` |
//! | a reply with the error headers of ADR-32 | `.failure`; the code from `Zefir-Rpc-Code`, else by the number; `refused` from `Zefir-Rpc-Refused` |
//! | `NATS/1.0 503` without a payload: no responders | `error.Unavailable`: no server took it, or none serves the route (a typo, another version) |
//! | any other status line | `error.ProtocolViolation` |
//! | no reply by the deadline | `error.Timeout` |
//! | the caller's task canceled | `error.Canceled`; the server is not told |
//!
//! And the errors of the connection:
//!
//! | Where | Error | `call` returns |
//! |---|---|---|
//! | before sending | no link (`isConnected`) | `error.Unavailable` |
//! | publish | PayloadTooLarge / PermissionDenied / Disconnected, ConnectionClosed / Timeout | RequestTooLarge / AccessDenied / Unavailable / Timeout |
//! | the inbox | PermissionDenied on its subscription | `error.AccessDenied`; the next call tries again |
//! | the inbox | ConnectionClosed | ConnectionLost to the calls that wait, Unavailable to new ones |
//! | the inbox | Disconnected | the calls wait on until their deadlines |
//!
//! The transport never closes the connection, and its `deinit` comes
//! before the connection's. The allocator must be thread-safe: calls are
//! allocated and freed from the tasks of the engine.

const std = @import("std");
const core = @import("core");
const rpc = @import("rpc");
const Conn = @import("Conn.zig");
const subject = @import("subject.zig");
const server_side = @import("server.zig");
const client_side = @import("client.zig");

const Transport = @This();

gpa: std.mem.Allocator,
conn: Conn,
options: Options,
/// The copies of the strings of `options`: `options` points here.
strings: []u8,
/// The copy of `options.reply_prefixes`.
reply_prefixes: [][]const u8,
pending: rpc.transport.Pending,
/// The `std.Io` the transport was first used with; Debug checks that every
/// call brings the same.
io_vtable: std.atomic.Value(?*const std.Io.VTable) = .init(null),
counts: std.EnumArray(Counter, std.atomic.Value(u64)) = .initFill(.init(0)),
server: server_side.State = .{},
client: client_side.State = .{},

pub const Options = struct {
    /// The first tokens of every subject, such as "shop": then a method
    /// lives on `shop.users.v1.getUser`. For systems that share a NATS
    /// cluster without NATS accounts; the server and its clients need the
    /// same prefix. Null: none.
    subject_prefix: ?[]const u8 = null,
    /// The queue group of the server's subscriptions: the replicas of a
    /// service share its requests. "q", as in the NATS Service API.
    queue_group: []const u8 = "q",
    /// The first tokens of the client's inbox, `<inbox_prefix>.<random
    /// token>`: NATS permissions can give every service an inbox of its
    /// own, such as "_INBOX_orders" with the right to subscribe to
    /// `_INBOX_orders.>`. The servers it calls must accept it in
    /// `reply_prefixes`.
    inbox_prefix: []const u8 = "_INBOX",
    /// The server answers only to a reply subject whose first token starts
    /// with one of these (`_INBOX` takes `_INBOX` and `_INBOX_orders`), so
    /// no one can send the responses of a service to a subject of their
    /// choice. NATS permissions (`allow_responses`) are the main guard;
    /// this is the second line.
    reply_prefixes: []const []const u8 = &.{"_INBOX"},
    /// How long `start` waits for the broker to confirm the subscriptions,
    /// and `close` for the last responses: the timeout of their flush.
    flush_timeout: std.Io.Duration = .fromSeconds(5),
    /// How long `Reply.send` waits for room to publish a response.
    publish_timeout: std.Io.Duration = .fromSeconds(5),
    /// The client's calls that wait for their responses at once; one more
    /// gets `error.TooManyPendingRequests`.
    max_pending: u32 = 1024,
};

pub const InitError = error{
    /// A prefix or the queue group is not tokens of `[A-Za-z0-9_-]`
    /// joined by dots, or is too long for a subject of 255 bytes; the
    /// subject prefix starts with `_INBOX`; `reply_prefixes` is empty or
    /// holds a string that is no token; a timeout or `max_pending` is not
    /// above zero.
    InvalidConfiguration,
    OutOfMemory,
};

/// What the transport dropped or lost, for metrics and tests.
pub const Counters = struct {
    /// Requests the server dropped: they had no reply subject.
    requests_without_reply_to: u64,
    /// Requests the server dropped: their reply subject is not under
    /// `reply_prefixes`.
    requests_with_foreign_reply_to: u64,
    /// Responses that found no call waiting: they came after `Timeout` or
    /// `Canceled`, or are foreign.
    late_responses: u64,
    /// Times a subscription of the transport lost messages as a slow
    /// consumer.
    slow_consumer_errors: u64,
};

pub const Counter = enum {
    requests_without_reply_to,
    requests_with_foreign_reply_to,
    late_responses,
    slow_consumer_errors,
};

/// A transport on `conn`, which must outlive it. Copies the strings of
/// `options` and takes the memory for `max_pending` waiting calls.
pub fn init(gpa: std.mem.Allocator, conn: Conn, options: Options) InitError!Transport {
    try check(options);
    var strings_len: usize = options.queue_group.len + options.inbox_prefix.len;
    if (options.subject_prefix) |prefix| strings_len += prefix.len;
    for (options.reply_prefixes) |prefix| strings_len += prefix.len;
    const strings = try gpa.alloc(u8, strings_len);
    errdefer gpa.free(strings);
    const reply_prefixes = try gpa.alloc([]const u8, options.reply_prefixes.len);
    errdefer gpa.free(reply_prefixes);
    var at: usize = 0;
    const copy = struct {
        fn put(buffer: []u8, offset: *usize, s: []const u8) []const u8 {
            const out = buffer[offset.*..][0..s.len];
            @memcpy(out, s);
            offset.* += s.len;
            return out;
        }
    }.put;
    var owned = options;
    owned.queue_group = copy(strings, &at, options.queue_group);
    owned.inbox_prefix = copy(strings, &at, options.inbox_prefix);
    if (options.subject_prefix) |prefix| owned.subject_prefix = copy(strings, &at, prefix);
    for (options.reply_prefixes, reply_prefixes) |prefix, *out| out.* = copy(strings, &at, prefix);
    owned.reply_prefixes = reply_prefixes;
    return .{
        .gpa = gpa,
        .conn = conn,
        .options = owned,
        .strings = strings,
        .reply_prefixes = reply_prefixes,
        .pending = try .init(gpa, .{ .max_pending = options.max_pending }),
    };
}

fn check(options: Options) error{InvalidConfiguration}!void {
    if (options.subject_prefix) |prefix| if (!subject.isSubjectPrefix(prefix)) return error.InvalidConfiguration;
    if (options.queue_group.len > subject.max_subject_bytes or !subject.isTokens(options.queue_group)) return error.InvalidConfiguration;
    if (!subject.isInboxPrefix(options.inbox_prefix)) return error.InvalidConfiguration;
    if (options.reply_prefixes.len == 0) return error.InvalidConfiguration;
    for (options.reply_prefixes) |prefix| {
        if (prefix.len > subject.max_subject_bytes or !subject.isToken(prefix)) return error.InvalidConfiguration;
    }
    if (options.flush_timeout.nanoseconds <= 0 or options.publish_timeout.nanoseconds <= 0) return error.InvalidConfiguration;
    if (options.max_pending == 0) return error.InvalidConfiguration;
}

/// Frees the transport: after the server's `deinit` and after the last
/// call has returned. A server side still running is closed first. Panics
/// while the engine holds the `Reply` of a call, or a call waits: deinit
/// the server and let every call return first.
pub fn deinit(t: *Transport, io: std.Io) void {
    server_side.close(t, io);
    client_side.stop(t, io);
    if (t.server.live_calls.load(.acquire) != 0)
        @panic("rpc_nats.Transport: deinit with calls not released; deinit the server and let every call return first");
    t.pending.deinit();
    t.gpa.free(t.reply_prefixes);
    t.gpa.free(t.strings);
    t.* = undefined;
}

/// The server side, for the engine of the server.
pub fn serverTransport(t: *Transport) rpc.ServerTransport {
    return .init(t);
}

/// The client side, for the engine of the client.
pub fn clientTransport(t: *Transport) rpc.ClientTransport {
    return .init(t);
}

/// The same for both sides: NATS request-reply. The broker tells a client
/// that no server took a request (no responders), and the server marks a
/// refused call; a link that breaks is seen only when the connection closes
/// for good. The largest body is the broker's `max_payload`, which
/// `publish` enforces.
pub fn info(t: *Transport) rpc.transport.Info {
    _ = t;
    return .{
        .name = "nats",
        .propagates_cancellation = false,
        .reports_unprocessed = true,
        .reports_connection_loss = false,
        .delivery = .at_most_once,
        .max_body_bytes = null,
    };
}

/// Publishes `request` to the subject of its route and waits for the
/// response in the inbox, by the rules of `rpc.ClientTransport.call`.
pub fn call(t: *Transport, io: std.Io, request: *const rpc.transport.Request, options: rpc.ClientTransport.CallOptions) rpc.ClientTransport.CallError!rpc.Response {
    return client_side.call(t, io, request, options);
}

/// Subscribes to the routes of `dispatcher` and starts taking requests; see
/// `rpc.ServerTransport.start`. A second `start` while one runs gets
/// `error.AddressInUse`; after `close` the transport may start again.
pub fn start(t: *Transport, io: std.Io, dispatcher: rpc.transport.Dispatcher) rpc.ServerTransport.StartError!void {
    return server_side.start(t, io, dispatcher);
}

/// Drains the subscriptions: the broker sends new requests to other
/// replicas, and the requests already on their way are still served.
pub fn drain(t: *Transport, io: std.Io) void {
    server_side.drain(t, io);
}

/// Stops taking requests for good; see `rpc.ServerTransport.close`.
pub fn close(t: *Transport, io: std.Io) void {
    server_side.close(t, io);
}

/// Whether the link to the broker is up.
pub fn isReady(t: *Transport) bool {
    return t.conn.isConnected();
}

/// What the transport has dropped or lost so far.
pub fn counters(t: *const Transport) Counters {
    var result: Counters = undefined;
    inline for (comptime std.enums.values(Counter)) |counter| {
        @field(result, @tagName(counter)) = t.counts.getPtrConst(counter).load(.monotonic);
    }
    return result;
}

/// One more of `counter`. Internal to the module.
pub fn count(t: *Transport, counter: Counter) void {
    _ = t.counts.getPtr(counter).fetchAdd(1, .monotonic);
}

/// In Debug, panics when `io` is another `std.Io` than the transport's
/// first one: canceling a task would not end a wait inside the library.
/// Internal to the module.
pub fn checkIo(t: *Transport, io: std.Io) void {
    if (!std.debug.runtime_safety) return;
    const first = t.io_vtable.cmpxchgStrong(null, io.vtable, .acq_rel, .acquire) orelse return;
    if (first != io.vtable) @panic("rpc_nats.Transport: called with another std.Io than before; pass the one the NATS connection runs on");
}

/// A timeout that ends `duration` from now; saturates. Internal to the
/// module.
pub fn timeoutAfter(io: std.Io, duration: std.Io.Duration) std.Io.Timeout {
    const deadline: core.Deadline = .after(std.Io.Clock.awake.now(io), duration);
    return deadline.toTimeout();
}

test {
    _ = server_side;
    _ = client_side;
}

const testing = std.testing;

const Unused = struct {
    pub fn publish(self: *@This(), io: std.Io, msg: Conn.OutMsg, timeout: std.Io.Timeout) Conn.Error!void {
        _ = self;
        _ = io;
        _ = msg;
        _ = timeout;
        return error.ConnectionClosed;
    }
    pub fn subscribe(self: *@This(), io: std.Io, subject_: []const u8, queue: ?[]const u8, timeout: std.Io.Timeout) Conn.Error!Conn.Sub {
        _ = io;
        _ = subject_;
        _ = queue;
        _ = timeout;
        return self;
    }
    pub fn next(self: *@This(), io: std.Io, sub: Conn.Sub, timeout: std.Io.Timeout) Conn.Error!?Conn.InMsg {
        _ = self;
        _ = io;
        _ = sub;
        _ = timeout;
        return null;
    }
    pub fn drain(self: *@This(), io: std.Io, sub: Conn.Sub) Conn.Error!void {
        _ = self;
        _ = io;
        _ = sub;
    }
    pub fn unsubscribe(self: *@This(), io: std.Io, sub: Conn.Sub) void {
        _ = self;
        _ = io;
        _ = sub;
    }
    pub fn flush(self: *@This(), io: std.Io, timeout: std.Io.Timeout) Conn.Error!void {
        _ = self;
        _ = io;
        _ = timeout;
    }
};

test "init copies the options and refuses wrong ones" {
    var unused: Unused = .{};
    var prefix = "shop".*;
    var reply = "_INBOX_shop".*;
    const replies = [_][]const u8{&reply};
    var bus: Transport = try .init(testing.allocator, .init(&unused), .{ .subject_prefix = &prefix, .reply_prefixes = &replies, .inbox_prefix = "_INBOX_shop" });
    defer bus.deinit(testing.io);
    prefix = "XXXX".*;
    reply = "XXXXXXXXXXX".*;
    try testing.expectEqualStrings("shop", bus.options.subject_prefix.?);
    try testing.expectEqualStrings("_INBOX_shop", bus.options.reply_prefixes[0]);
    try testing.expectEqualStrings("q", bus.options.queue_group);
    try testing.expectEqualStrings("_INBOX_shop", bus.options.inbox_prefix);

    const wrong = [_]Options{
        .{ .subject_prefix = "" },
        .{ .subject_prefix = "shop." },
        .{ .subject_prefix = "_INBOX" },
        .{ .subject_prefix = "a b" },
        .{ .queue_group = "" },
        .{ .queue_group = "q q" },
        .{ .inbox_prefix = "" },
        .{ .inbox_prefix = "_INBOX.*" },
        .{ .reply_prefixes = &.{} },
        .{ .reply_prefixes = &.{"_INBOX.x"} },
        .{ .reply_prefixes = &.{""} },
        .{ .flush_timeout = .zero },
        .{ .publish_timeout = .fromNanoseconds(-1) },
        .{ .max_pending = 0 },
    };
    for (wrong) |options| try testing.expectError(error.InvalidConfiguration, Transport.init(testing.allocator, .init(&unused), options));
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn make(gpa: std.mem.Allocator) !void {
            var adapter: Unused = .{};
            var t: Transport = try .init(gpa, .init(&adapter), .{ .subject_prefix = "shop", .reply_prefixes = &.{ "_INBOX", "_INBOX_x" } });
            t.deinit(testing.io);
        }
    }.make, .{});
}

test "info: NATS request-reply" {
    var unused: Unused = .{};
    var bus: Transport = try .init(testing.allocator, .init(&unused), .{});
    defer bus.deinit(testing.io);
    const info_ = bus.info();
    try testing.expectEqualStrings("nats", info_.name);
    try testing.expect(!info_.propagates_cancellation);
    try testing.expect(info_.reports_unprocessed);
    try testing.expect(!info_.reports_connection_loss);
    try testing.expectEqual(rpc.transport.Delivery.at_most_once, info_.delivery);
    try testing.expectEqual(@as(?usize, null), info_.max_body_bytes);
    try testing.expect(bus.isReady());
}
