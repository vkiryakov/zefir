//! The NATS transport of rpc: one object for both sides, on one NATS
//! connection that the application owns. The server engine gets
//! `serverTransport()`, its clients get `clientTransport()`.
//!
//! ```zig
//! var bus: rpc_nats.Transport = try .init(gpa, &nc, .{}); // nc: a nats.Client
//! defer bus.deinit(io); // after the server's deinit and the last call
//! var server: rpc.Server = try .init(gpa, .{ .handlers = .{&users} }, .{ .transport = bus.serverTransport() });
//! ```
//!
//! `init` takes a `nats.Client` and makes the adapter of zefir-nats,
//! `rpc_nats.ZefirNats`, on the heap; `initConn` takes the `rpc_nats.Conn`
//! of any adapter: one of zefir-nats with a `pending` of its own, one of
//! another NATS library, or `rpc_nats.testing.FakeConn`.
//!
//! The server subscribes to the subject of every route in the queue group
//! `queue_group`, so the replicas of a service share its requests, and
//! confirms the subscriptions with a flush: a subject the NATS permissions
//! deny fails `start` with AccessDenied. It answers only to a reply subject
//! under `reply_prefixes`, and only to a request with one. A request from
//! `nats req`, without the headers of zefir, is served too. Every contract
//! of the server is a NATS micro service, unless `discovery` says no: the
//! subscriptions of `$SRV.PING`, `$SRV.INFO` and `$SRV.STATS` start, drain
//! and close with those of the routes.
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
//! returns within `publish_timeout` plus `flush_timeout`: a receiving task
//! first hands over or refuses the request it holds, and a refusal waits
//! for room to publish no longer than `publish_timeout`; then the flush of
//! the responses sent so far waits no longer than `flush_timeout`. A
//! `close` straight from running, without `drain` before it, drains the
//! subscriptions too, and that takes as long as the adapter's `drain`.
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
//! The message, the app code and the field of a failure travel as headers:
//! they count toward `max_response_metadata_bytes` with the metadata, so a
//! reply takes no more of the caller's memory than its limits.
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
//! allocated and freed from the tasks of the engine. `serverTransport()`
//! and `clientTransport()` point at the transport, and so do its tasks:
//! from the first of them to `deinit` it stays where it is, never copied
//! or moved. Before that it may move, as zefir.App moves the value a
//! factory returns into its memory: nothing points at it yet, and the
//! adapter of `init` lives on the heap.

const std = @import("std");
const rpc = @import("rpc");
const nats = @import("nats");
const Conn = @import("Conn.zig");
const ZefirNats = @import("ZefirNats.zig");
const subject = @import("subject.zig");
const shared = @import("shared.zig");
const server_side = @import("server.zig");
const client_side = @import("client.zig");

const Transport = @This();

gpa: std.mem.Allocator,
conn: Conn,
/// The adapter `init` made for `conn`, on the heap; null after `initConn`.
adapter: ?*ZefirNats = null,
options: Options,
/// The copies of the strings of `options`: `options` points here.
strings: []u8,
/// The copy of `options.reply_prefixes`.
reply_prefixes: [][]const u8,
pending: rpc.transport.Pending,
/// The `std.Io` the transport was first used with; safe builds (Debug and
/// ReleaseSafe) check that every call brings the same.
io_vtable: std.atomic.Value(?*const std.Io.VTable) = .init(null),
counts: std.EnumArray(shared.Counter, std.atomic.Value(u64)) = .initFill(.init(0)),
/// Held by the server side's `start` from its first SUB to the flush that
/// confirms them, by the client from the SUB of its inbox to its flush,
/// and by the flush of `close`: a connection tells of a refused SUB at the
/// first flush after it, which must be the flush of the side that made it.
confirming: std.Io.Mutex = .init,
server: server_side.State = .{},
client: client_side.State = .{},

/// zefir.App builds and frees this transport, but its start, drain and close
/// belong to the rpc server: App does not drive them.
pub const app_lifecycle = false;

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
    /// NATS micro discovery (ADR-32), on by default: every contract of the
    /// server is a NATS micro service, so `nats micro ls`, `nats micro info
    /// users` and `nats micro stats users` see its replicas, its methods
    /// and their counters. It subscribes to subjects under `$SRV.`, which
    /// the NATS permissions of the service must allow.
    discovery: Discovery = .{},

    pub const Discovery = struct {
        /// False: no NATS micro subscriptions at all.
        enabled: bool = true,
    };
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

/// A transport on `client`, which must outlive it, through an adapter
/// `rpc_nats.ZefirNats` of its own on the heap, with the default `pending`.
/// Copies the strings of `options` and takes the memory for `max_pending`
/// waiting calls. In a factory of zefir.App, the transport is a bean on
/// the bean of the client:
///
/// ```zig
/// pub fn bus(gpa: std.mem.Allocator, client: *nats.Client) !rpc_nats.Transport {
///     return .init(gpa, client, .{});
/// }
/// ```
pub fn init(gpa: std.mem.Allocator, client: *nats.Client, options: Options) InitError!Transport {
    const adapter = try gpa.create(ZefirNats);
    errdefer gpa.destroy(adapter);
    adapter.* = .{ .client = client };
    var t = try initConn(gpa, adapter.conn(), options);
    t.adapter = adapter;
    return t;
}

/// A transport on `conn`, which must outlive it: an adapter of zefir-nats
/// with a `pending` of its own, an adapter of another NATS library, or
/// `rpc_nats.testing.FakeConn`. Copies the strings of `options` and takes
/// the memory for `max_pending` waiting calls.
pub fn initConn(gpa: std.mem.Allocator, conn: Conn, options: Options) InitError!Transport {
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
    // An allocator may take a cancelable lock; a cancelation of the caller
    // stays for later.
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    server_side.close(t, io);
    client_side.stop(t, io);
    if (t.server.live_calls.load(.acquire) != 0)
        @panic("rpc_nats.Transport: deinit with calls not released; deinit the server and let every call return first");
    t.pending.deinit();
    t.gpa.free(t.reply_prefixes);
    t.gpa.free(t.strings);
    if (t.adapter) |adapter| t.gpa.destroy(adapter);
    t.* = undefined;
}

/// The server side, for the engine of the server. It points at `t`, which
/// stays where it is until `deinit`.
pub fn serverTransport(t: *Transport) rpc.ServerTransport {
    return .init(t);
}

/// The client side, for the engine of the client. It points at `t`, which
/// stays where it is until `deinit`.
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
    inline for (comptime std.enums.values(shared.Counter)) |counter| {
        @field(result, @tagName(counter)) = t.counts.getPtrConst(counter).load(.monotonic);
    }
    return result;
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
    var bus: Transport = try .initConn(testing.allocator, .init(&unused), .{ .subject_prefix = &prefix, .reply_prefixes = &replies, .inbox_prefix = "_INBOX_shop" });
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
    for (wrong) |options| try testing.expectError(error.InvalidConfiguration, Transport.initConn(testing.allocator, .init(&unused), options));
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn make(gpa: std.mem.Allocator) !void {
            var adapter: Unused = .{};
            var t: Transport = try .initConn(gpa, .init(&adapter), .{ .subject_prefix = "shop", .reply_prefixes = &.{ "_INBOX", "_INBOX_x" } });
            t.deinit(testing.io);
        }
    }.make, .{});
}

test "info: NATS request-reply" {
    var unused: Unused = .{};
    var bus: Transport = try .initConn(testing.allocator, .init(&unused), .{});
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
