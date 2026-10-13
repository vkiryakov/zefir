//! A client of a NATS server.
//!
//! ```zig
//! var client: nats.Client = try .init(gpa, io, .{ .servers = &.{"nats://127.0.0.1:4222"} });
//! defer client.deinit();
//! try client.connect();
//! try client.publish("orders.new", "{\"id\":42}");
//! try client.flush(.{});
//! ```
//!
//! `connect()` starts the client's tasks, which keep a pointer to it: from
//! then on the client must stay where it is, so do not move or copy it.
//! Every method may be called from any task at the same time. The
//! allocator must be thread-safe. The `io` needs real concurrency, such as
//! `std.Io.Threaded` or zio; without it `connect()` fails with
//! ConcurrencyUnavailable.
//!
//! In this version a lost connection closes the client, ends its
//! subscriptions and fails its requests with Disconnected.
//!
//! The fields are internal: use the methods. Tests may ask
//! `outbound.roomWaiters()` whether a publish waits for room, and
//! `inbox.pendingCount()`, `inbox.awaitingCount()` and
//! `inbox.lateResponses()` about requests.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Options = @import("Options.zig");
const ServerAddress = @import("ServerAddress.zig");
const ServerInfo = @import("ServerInfo.zig");
const Message = @import("Message.zig");
const PublishMessage = Message.PublishMessage;
const ResponseMessage = Message.ResponseMessage;
const Subscription = @import("Subscription.zig");
const Responses = @import("Responses.zig");
const Headers = @import("Headers.zig");
const Parser = @import("protocol/Parser.zig");
const encoder = @import("protocol/encoder.zig");
const subjects = @import("protocol/subject.zig");
const OwnedOptions = @import("engine/OwnedOptions.zig");
const Outbound = @import("engine/Outbound.zig");
const Registry = @import("engine/Registry.zig");
const Inbox = @import("engine/Inbox.zig");
const MessageQueue = @import("engine/MessageQueue.zig");
const Connection = @import("engine/Connection.zig");
const dialer = @import("engine/connect.zig");
const manager = @import("engine/manager.zig");
const time = @import("engine/time.zig");
const log = std.log.scoped(.nats);
const Client = @This();

gpa: Allocator,
io: Io,
options: OwnedOptions,
/// The read buffer of every connection: the longest line the server may
/// send fits in it.
read_buffer: []u8,
parser_limits: Parser.Limits,
outbound: Outbound,
/// The subscriptions by SID.
subscriptions: Registry = .{},
/// The inbox subscription and the requests waiting for replies.
inbox: Inbox = .{},
/// The manager task.
tasks: Io.Group = .init,
/// The reader and writer of the current connection.
connection_tasks: Io.Group = .init,
/// The current connection; only the manager opens and closes it.
connection: Connection = undefined,

/// Held while connect, close and deinit start or stop the manager.
lifecycle: Io.Mutex = .init,
/// Guards the fields below.
mutex: Io.Mutex = .init,
/// Broadcast on every change of the fields below.
changed: Io.Condition = .init,
status: State = .disconnected,
/// Why the current connection must end; the manager acts on it.
exit: ?manager.Exit = null,
/// The attempt to connect in progress, for `close()` to stop.
attempt: ?*manager.AttemptState = null,
/// Why the first connection failed, for `connect()` to return.
connect_error: ?ConnectError = null,
/// The server of the current connection.
server: ?ServerAddress = null,
/// The JSON of the latest INFO of the current connection.
info_json: ?[]u8 = null,
/// The current connection takes headers: CONNECT asked for them.
server_headers: bool = false,
/// The `max_payload` of the latest INFO; 0 when the server gave none.
max_payload: u64 = 0,
/// `deinit` has run.
freed: bool = false,

/// Where the client is in its life.
pub const State = enum {
    /// `connect()` has not been called yet.
    disconnected,
    /// `connect()` is opening the first connection.
    connecting,
    connected,
    /// The connection was lost and a new one is being opened.
    reconnecting,
    /// Finishing its work before it closes.
    draining,
    /// Closed for good.
    closed,
};

pub const InitError = Options.Error || Allocator.Error;

pub const ConnectError = error{
    /// The client is closed: `close()` was called, or connecting failed.
    ConnectionClosed,
    /// The `io` cannot run the client's tasks.
    ConcurrencyUnavailable,
} || dialer.DialError || Connection.HandshakeError;

pub const FlushError = error{
    /// Not connected yet.
    Disconnected,
    ConnectionClosed,
    Timeout,
    Canceled,
    OutOfMemory,
};

pub const ServerInfoError = error{ OutOfMemory, ProtocolError };

pub const PublishError = error{
    /// The subject or reply subject cannot be published to, or the line
    /// would be longer than `limits.max_control_line_bytes`.
    InvalidSubject,
    InvalidHeader,
    /// Headers and payload together exceed the server's `max_payload`.
    PayloadTooLarge,
    /// Headers, and the server cannot take them.
    UnsupportedFeature,
    /// Not connected yet.
    Disconnected,
    ConnectionClosed,
    Canceled,
    OutOfMemory,
    /// A bug in this client: the frame came out of another length.
    ProtocolError,
};

/// Publishes `payload` to `subject`. It returns once a copy is in the
/// outbound queue, which is not delivery: `flush` waits until the server
/// has it. While the queue is full, it waits for room; cancel the task to
/// give up.
pub fn publish(client: *Client, subject: []const u8, payload: []const u8) PublishError!void {
    return client.publishMessage(.{ .subject = subject, .payload = payload });
}

/// Publishes `message`, with its reply subject and headers, the way
/// `publish` does. Headers need a server that supports them.
pub fn publishMessage(client: *Client, message: PublishMessage) PublishError!void {
    const header_len = try client.prepare(message);
    try client.checkLine(message, header_len);
    const io = client.io;
    const has_headers = message.headers.len > 0;
    const queued = if (has_headers)
        client.outbound.put(io, .publish, encoder.hpubLen(message.subject, message.reply_to, header_len, message.payload.len), encoder.writeHpub, .{
            message.subject, message.reply_to, message.headers, message.payload,
        })
    else
        client.outbound.put(io, .publish, encoder.pubLen(message.subject, message.reply_to, message.payload.len), encoder.writePub, .{
            message.subject, message.reply_to, message.payload,
        });
    queued catch |err| switch (err) {
        error.Closed => return error.ConnectionClosed,
        else => |e| return e,
    };
}

pub const RespondError = PublishError || error{
    /// The message has no reply subject: no one waits for an answer.
    NoReplySubject,
};

/// Answers `msg`, a request that came to a subscription: publishes
/// `payload` to its reply subject, the way `publish` does.
///
/// ```zig
/// var msg = (try sub.next(.{})) orelse return;
/// defer msg.deinit();
/// try client.respond(&msg, "done");
/// ```
pub fn respond(client: *Client, msg: *const Message, payload: []const u8) RespondError!void {
    return client.respondMessage(msg, .{ .payload = payload });
}

/// Answers `msg` with headers, or with a reply subject of its own, the way
/// `respond` does.
pub fn respondMessage(client: *Client, msg: *const Message, response: ResponseMessage) RespondError!void {
    const reply = msg.reply_to orelse return error.NoReplySubject;
    return client.publishMessage(.{ .subject = reply, .reply_to = response.reply_to, .headers = response.headers, .payload = response.payload });
}

const PrepareError = error{ InvalidSubject, InvalidHeader, UnsupportedFeature, PayloadTooLarge, Disconnected, ConnectionClosed };

/// Checks `message` against the rules and the current connection, all but
/// the length of its line; gives the length of its header block.
fn prepare(client: *Client, message: PublishMessage) PrepareError!usize {
    try subjects.validatePublish(message.subject);
    if (message.reply_to) |reply| try subjects.validatePublish(reply);
    try Headers.validate(message.headers);
    const server = try client.currentServer();
    const has_headers = message.headers.len > 0;
    if (has_headers and !server.headers) return error.UnsupportedFeature;
    const header_len = if (has_headers) encoder.headerBlockLen(message.headers) else 0;
    const total = std.math.add(usize, header_len, message.payload.len) catch return error.PayloadTooLarge;
    if (!fitsPayload(total, server.max_payload)) return error.PayloadTooLarge;
    return header_len;
}

/// The server closes the connection on a line with longer arguments.
fn checkLine(client: *Client, message: PublishMessage, header_len: usize) error{InvalidSubject}!void {
    const args_len = if (message.headers.len > 0)
        encoder.hpubArgsLen(message.subject, message.reply_to, header_len, message.payload.len)
    else
        encoder.pubArgsLen(message.subject, message.reply_to, message.payload.len);
    if (args_len > client.options.options.limits.max_control_line_bytes) return error.InvalidSubject;
}

/// Queues the PUB or HPUB of a request, waiting for room until `deadline`.
fn queueRequest(client: *Client, message: PublishMessage, header_len: usize, deadline: Io.Clock.Timestamp) Outbound.PutUntilError!void {
    const io = client.io;
    if (message.headers.len > 0) {
        return client.outbound.putUntil(io, deadline, .request, encoder.hpubLen(message.subject, message.reply_to, header_len, message.payload.len), encoder.writeHpub, .{
            message.subject, message.reply_to, message.headers, message.payload,
        });
    }
    return client.outbound.putUntil(io, deadline, .request, encoder.pubLen(message.subject, message.reply_to, message.payload.len), encoder.writePub, .{
        message.subject, message.reply_to, message.payload,
    });
}

pub const SubscribeError = error{
    /// The subject cannot be subscribed to, or the SUB line would be
    /// longer than `limits.max_control_line_bytes`.
    InvalidSubject,
    /// A queue group name with whitespace, `max_messages` of 0 or over
    /// 999 999 999, or a pending limit of 0.
    InvalidOptions,
    /// `limits.max_subscriptions` subscriptions exist already.
    TooManySubscriptions,
    /// Not connected yet.
    Disconnected,
    ConnectionClosed,
    Canceled,
    OutOfMemory,
    /// A bug in this client: the frame came out of another length.
    ProtocolError,
};

/// Subscribes to `subject`, which may hold wildcards. The SUB is queued
/// before this returns; `flush` makes sure the server has it. The
/// subscription is the client's: free it with its `deinit()`.
pub fn subscribe(client: *Client, subject: []const u8, options: Subscription.Options) SubscribeError!*Subscription {
    try subjects.validateSubscribe(subject);
    if (options.queue) |queue| {
        if (!subjects.isValidQueue(queue)) return error.InvalidOptions;
    }
    if (options.max_messages) |max| {
        if (max == 0 or max > encoder.max_size) return error.InvalidOptions;
    }
    const limits = client.options.options.limits;
    const pending: MessageQueue.Limits = .{
        .messages = options.pending.messages orelse limits.subscription_messages,
        .bytes = options.pending.bytes orelse limits.subscription_bytes,
    };
    if (pending.messages == 0 or pending.bytes == 0) return error.InvalidOptions;
    _ = try client.currentServer();

    const io = client.io;
    const gpa = client.gpa;
    const sub = try Registry.create(gpa, client, subject, options, pending);
    errdefer Registry.destroy(gpa, sub);
    try client.subscriptions.register(io, gpa, sub, limits.max_subscriptions);
    errdefer client.subscriptions.unregister(io, sub.sid);
    // The server closes the connection on a longer line.
    if (encoder.subArgsLen(sub.subject, sub.queue_group, sub.sid) > limits.max_control_line_bytes) return error.InvalidSubject;
    const len = subscribeLen(sub.subject, sub.queue_group, sub.sid, options.max_messages);
    client.outbound.put(io, .service, len, writeSubscribe, .{ sub.subject, sub.queue_group, sub.sid, options.max_messages }) catch |err| switch (err) {
        error.Closed => return error.ConnectionClosed,
        else => |e| return e,
    };
    return sub;
}

/// SUB and, with `max`, the UNSUB that ends the subscription after `max`
/// messages: one frame of the queue, so neither goes without the other.
fn writeSubscribe(w: *Io.Writer, subject: []const u8, queue: ?[]const u8, sid: u64, max: ?u64) Io.Writer.Error!void {
    try encoder.writeSub(w, subject, queue, sid);
    if (max) |m| try encoder.writeUnsub(w, sid, m);
}

fn subscribeLen(subject: []const u8, queue: ?[]const u8, sid: u64, max: ?u64) usize {
    return encoder.subLen(subject, queue, sid) + if (max) |m| encoder.unsubLen(sid, m) else 0;
}

/// What publishing needs to know about the current connection.
const ServerFacts = struct { headers: bool, max_payload: u64 };

fn currentServer(client: *Client) error{ Disconnected, ConnectionClosed }!ServerFacts {
    client.mutex.lockUncancelable(client.io);
    defer client.mutex.unlock(client.io);
    return switch (client.status) {
        .connected => .{ .headers = client.server_headers, .max_payload = client.max_payload },
        .closed => error.ConnectionClosed,
        .disconnected, .connecting, .reconnecting, .draining => error.Disconnected,
    };
}

/// A message of `total` bytes, headers included, that the server takes:
/// within its `max_payload` when it gave one (0 when not), and never more
/// than its parser reads.
fn fitsPayload(total: usize, max_payload: u64) bool {
    if (total > encoder.max_size) return false;
    return max_payload == 0 or total <= max_payload;
}

pub const FlushOptions = struct {
    /// How long to wait for the server's PONG.
    timeout: Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } },
};

pub const RequestOptions = struct {
    /// How long the request may take in all, the wait for room in the
    /// outbound queue included. Every request ends: `.none` is refused.
    timeout: Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(2), .clock = .awake } },
};

pub const RequestError = error{
    /// The subject cannot be published to, or the line would be longer
    /// than `limits.max_control_line_bytes`.
    InvalidSubject,
    InvalidHeader,
    /// The timeout is `.none`, or the message has a reply subject: a
    /// request uses its own.
    InvalidOptions,
    /// Headers and payload together exceed the server's `max_payload`.
    PayloadTooLarge,
    /// Headers, and the server cannot take them.
    UnsupportedFeature,
    /// `limits.max_pending_requests` requests wait for replies already.
    TooManyPendingRequests,
    /// No reply came in time.
    Timeout,
    /// No one subscribes to the subject.
    NoResponders,
    /// Not connected yet, or the connection was lost while the request
    /// waited.
    Disconnected,
    ConnectionClosed,
    Canceled,
    OutOfMemory,
    /// A bug in this client: the frame came out of another length.
    ProtocolError,
    /// The `std.Io` has no secure randomness for the inbox subject.
    EntropyUnavailable,
};

/// Sends `payload` to `subject` and waits for one reply, which is the
/// caller's: free it with its `deinit()`.
///
/// ```zig
/// var reply = try client.request("orders.status", "42", .{});
/// defer reply.deinit();
/// ```
///
/// Every request ends: at `options.timeout`, 2 s by default, with
/// Timeout, which also bounds the wait for room in the outbound queue.
/// A reply that comes after that is dropped and counted as late. If the
/// connection is lost meanwhile, the request fails with Disconnected at
/// once: nothing is sent again. All requests share one inbox subscription,
/// made by the first; any number may wait at once, up to
/// `limits.max_pending_requests`.
pub fn request(client: *Client, subject: []const u8, payload: []const u8, options: RequestOptions) RequestError!Message {
    return client.requestMessage(.{ .subject = subject, .payload = payload }, options);
}

/// Sends `message`, headers included, the way `request` does. Its
/// `reply_to` must be null: the reply subject is the client's.
pub fn requestMessage(client: *Client, message: PublishMessage, options: RequestOptions) RequestError!Message {
    if (message.reply_to != null or options.timeout == .none) return error.InvalidOptions;
    const header_len = try client.prepare(message);
    const io = client.io;
    const deadline = time.deadline(io, options.timeout).?;
    try client.inbox.subscribe(io, &client.subscriptions, &client.outbound, deadline);

    var waiter: Inbox.Waiter = .{};
    const id = try client.inbox.add(io, client.gpa, .{ .single = &waiter }, client.options.options.limits.max_pending_requests);
    // Whatever happens, the request leaves the pending map.
    defer client.inbox.drop(io, id, &waiter);
    var reply_buffer: [Inbox.max_reply_len]u8 = undefined;
    var with_reply = message;
    with_reply.reply_to = client.inbox.replySubject(&reply_buffer, id);
    try client.checkLine(with_reply, header_len);
    client.queueRequest(with_reply, header_len, deadline) catch |err| switch (err) {
        error.Closed => return client.inbox.closedError(io),
        else => |e| return e,
    };
    return client.inbox.await(io, id, &waiter, deadline);
}

pub const RequestManyOptions = struct {
    /// How long the whole exchange may take: the stream of responses ends
    /// then. Every request ends: `.none` is refused.
    timeout: Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(2), .clock = .awake } },
    /// The stream ends after this many responses, the dropped ones counted.
    max_responses: u32 = 32,
    /// The bytes of the responses waiting to be taken, subjects and headers
    /// included; a response that does not fit is dropped. Null:
    /// `limits.subscription_bytes`.
    max_bytes: ?usize = null,
};

pub const RequestManyError = error{
    /// The subject cannot be published to, or the line would be longer
    /// than `limits.max_control_line_bytes`.
    InvalidSubject,
    /// The timeout is `.none`, or `max_responses` or `max_bytes` is 0.
    InvalidOptions,
    /// The payload exceeds the server's `max_payload`.
    PayloadTooLarge,
    /// `limits.max_pending_requests` requests wait for replies already.
    TooManyPendingRequests,
    /// The request could not be queued in time.
    Timeout,
    /// Not connected yet.
    Disconnected,
    ConnectionClosed,
    Canceled,
    OutOfMemory,
    /// A bug in this client: the frame came out of another length.
    ProtocolError,
    /// The `std.Io` has no secure randomness for the inbox subject.
    EntropyUnavailable,
};

/// Sends `payload` to `subject` and returns the stream of the responses,
/// from any number of responders: scatter and gather. The stream ends at
/// `options.timeout`, 2 s by default, or after `max_responses`; see
/// `Responses`. It is the client's: free it with its `deinit()`.
pub fn requestMany(client: *Client, subject: []const u8, payload: []const u8, options: RequestManyOptions) RequestManyError!*Responses {
    if (options.timeout == .none or options.max_responses == 0) return error.InvalidOptions;
    if (options.max_bytes) |bytes| if (bytes == 0) return error.InvalidOptions;
    try subjects.validatePublish(subject);
    const server = try client.currentServer();
    if (!fitsPayload(payload.len, server.max_payload)) return error.PayloadTooLarge;
    const io = client.io;
    const gpa = client.gpa;
    const deadline = time.deadline(io, options.timeout).?;
    try client.inbox.subscribe(io, &client.subscriptions, &client.outbound, deadline);

    const limits = &client.options.options.limits;
    const responses = try Inbox.createResponses(gpa, client, deadline, .{
        .messages = options.max_responses,
        .bytes = options.max_bytes orelse limits.subscription_bytes,
    });
    errdefer Inbox.destroyResponses(gpa, responses);
    responses.id = try client.inbox.add(io, gpa, .{ .many = responses }, limits.max_pending_requests);
    // Out of the inbox before it is freed.
    errdefer client.inbox.remove(io, responses.id);
    var reply_buffer: [Inbox.max_reply_len]u8 = undefined;
    const message: PublishMessage = .{ .subject = subject, .reply_to = client.inbox.replySubject(&reply_buffer, responses.id), .payload = payload };
    try client.checkLine(message, 0);
    client.queueRequest(message, 0, deadline) catch |err| switch (err) {
        error.Closed => return client.inbox.closedError(io),
        else => |e| return e,
    };
    return responses;
}

/// Checks `options` and copies them, so the caller may free its strings at
/// once. Nothing touches the network before `connect()`.
pub fn init(gpa: Allocator, io: Io, options: Options) InitError!Client {
    var owned: OwnedOptions = try .init(gpa, options);
    errdefer owned.deinit(gpa);
    const parser_limits: Parser.Limits = .{ .max_control_line = owned.options.limits.max_control_line_bytes };
    return .{
        .gpa = gpa,
        .io = io,
        .options = owned,
        .read_buffer = try gpa.alloc(u8, Parser.bufferLen(parser_limits)),
        .parser_limits = parser_limits,
        .outbound = .init(gpa, owned.options.limits.outbound_bytes),
    };
}

/// Connects to the first of `servers` that takes the connection, one
/// attempt each, every attempt within `connect_timeout`. A failed connect
/// closes the client: create a new one to try again. A call made while
/// another one is connecting waits for that outcome; once the client is
/// connected, another call changes nothing.
pub fn connect(client: *Client) ConnectError!void {
    const io = client.io;
    {
        client.lifecycle.lockUncancelable(io);
        defer client.lifecycle.unlock(io);
        client.mutex.lockUncancelable(io);
        const status = client.status;
        if (status == .disconnected) client.status = .connecting;
        client.mutex.unlock(io);
        switch (status) {
            .disconnected => client.tasks.concurrent(io, manager.run, .{client}) catch |err| {
                manager.connectFailed(client, err);
                return err;
            },
            .connecting => {},
            .closed => return error.ConnectionClosed,
            .connected, .reconnecting, .draining => return,
        }
    }

    client.mutex.lockUncancelable(io);
    while (client.status == .connecting) {
        client.changed.wait(io, &client.mutex) catch |err| {
            // The caller gave up: the attempt stops and the client closes.
            client.mutex.unlock(io);
            client.close();
            return err;
        };
    }
    defer client.mutex.unlock(io);
    if (client.status == .connected) return;
    return client.connect_error orelse error.ConnectionClosed;
}

/// Waits until the server has processed everything this client sent
/// before: a PING goes out after it, and the server answers with PONG.
pub fn flush(client: *Client, options: FlushOptions) FlushError!void {
    _ = try client.ping(options.timeout);
}

/// How long a PING takes to come back as PONG.
pub fn rtt(client: *Client, options: FlushOptions) FlushError!Io.Duration {
    return client.ping(options.timeout);
}

fn ping(client: *Client, timeout: Io.Timeout) FlushError!Io.Duration {
    const io = client.io;
    const deadline = time.deadline(io, timeout);
    switch (client.state()) {
        .connected => {},
        .closed => return error.ConnectionClosed,
        .disconnected, .connecting, .reconnecting, .draining => return error.Disconnected,
    }
    const start = Io.Clock.awake.now(io);
    const number = client.outbound.putPing(io, .flush) catch |err| switch (err) {
        error.Closed => return error.ConnectionClosed,
        error.OutOfMemory => return error.OutOfMemory,
    };
    client.outbound.waitPong(io, number, deadline) catch |err| switch (err) {
        error.Closed => return error.ConnectionClosed,
        error.Timeout => return error.Timeout,
        error.Canceled => return error.Canceled,
    };
    return start.durationTo(Io.Clock.awake.now(io));
}

/// Closes the client at once: nothing still queued is sent, and every task
/// waiting in the client gets ConnectionClosed. For a careful stop, flush
/// first. Calling it again does nothing.
pub fn close(client: *Client) void {
    if (client.freed) return;
    const io = client.io;
    client.lifecycle.lockUncancelable(io);
    defer client.lifecycle.unlock(io);
    client.mutex.lockUncancelable(io);
    if (client.status != .closed) log.debug("closing the client", .{});
    client.status = .closed;
    if (client.exit == null) client.exit = .closed;
    // Under the lock: the attempt lives on the manager's stack until it is
    // untracked.
    if (client.attempt) |attempt| attempt.stop(io);
    client.changed.broadcast(io);
    client.mutex.unlock(io);
    // Before the outbound queue wakes them, requests learn why.
    client.inbox.end(io, .closed);
    client.outbound.close(io);
    // The manager closes its connection and returns.
    client.tasks.cancel(io);
    client.subscriptions.closeAll(io);
}

/// Closes the client if needed and frees everything, the subscriptions not
/// freed yet included. Calling it again does nothing. No other task may
/// use the client, or its subscriptions, any more.
pub fn deinit(client: *Client) void {
    if (client.freed) return;
    client.close();
    client.subscriptions.deinit(client.gpa);
    client.inbox.deinit(client.gpa);
    client.outbound.deinit();
    if (client.info_json) |json| client.gpa.free(json);
    client.gpa.free(client.read_buffer);
    client.options.deinit(client.gpa);
    client.freed = true;
}

pub fn state(client: *Client) State {
    client.mutex.lockUncancelable(client.io);
    defer client.mutex.unlock(client.io);
    return client.status;
}

pub fn isConnected(client: *Client) bool {
    return client.state() == .connected;
}

/// The server of the current connection; null when not connected. The
/// result is a copy: its `host()` points into it, so keep the copy while
/// you use the host.
pub fn connectedServer(client: *Client) ?ServerAddress {
    client.mutex.lockUncancelable(client.io);
    defer client.mutex.unlock(client.io);
    return if (client.status == .connected) client.server else null;
}

/// What the server of the current connection said about itself in its
/// latest INFO, parsed into memory from `gpa`: free it with `deinit()`.
/// Null when not connected.
pub fn serverInfo(client: *Client, gpa: Allocator) ServerInfoError!?std.json.Parsed(ServerInfo) {
    const json = copy: {
        client.mutex.lockUncancelable(client.io);
        defer client.mutex.unlock(client.io);
        if (client.status != .connected) return null;
        const json = client.info_json orelse return null;
        break :copy try gpa.dupe(u8, json);
    };
    defer gpa.free(json);
    return try ServerInfo.parse(gpa, json);
}

const testing = std.testing;
const one_server: []const []const u8 = &.{"nats://127.0.0.1:4222"};

test "init refuses bad options" {
    try testing.expectError(error.InvalidOptions, Client.init(testing.allocator, testing.io, .{ .servers = &.{} }));
    try testing.expectError(error.InvalidOptions, Client.init(testing.allocator, testing.io, .{ .servers = &.{"tls://a"} }));
}

test "before connect the client has no server" {
    var client: Client = try .init(testing.allocator, testing.io, .{ .servers = one_server });
    defer client.deinit();
    try testing.expectEqual(.disconnected, client.state());
    try testing.expect(!client.isConnected());
    try testing.expect(client.connectedServer() == null);
    try testing.expect(try client.serverInfo(testing.allocator) == null);
    try testing.expectError(error.Disconnected, client.flush(.{}));
    try testing.expectError(error.Disconnected, client.rtt(.{}));
}

test "close before connect, connect after close, deinit twice" {
    var client: Client = try .init(testing.allocator, testing.io, .{ .servers = one_server });
    client.close();
    try testing.expectEqual(.closed, client.state());
    try testing.expectError(error.ConnectionClosed, client.connect());
    try testing.expectError(error.ConnectionClosed, client.flush(.{}));
    client.close();
    client.deinit();
    client.deinit();
}

test "publish before connect is Disconnected, after close ConnectionClosed" {
    var client: Client = try .init(testing.allocator, testing.io, .{ .servers = one_server });
    defer client.deinit();
    try testing.expectError(error.Disconnected, client.publish("foo", "x"));
    // The arguments are checked first, whatever the state.
    try testing.expectError(error.InvalidSubject, client.publish("foo bar", "x"));
    client.close();
    try testing.expectError(error.ConnectionClosed, client.publish("foo", "x"));
    try testing.expectError(error.ConnectionClosed, client.publishMessage(.{ .subject = "foo", .headers = &.{.{ .name = "X", .value = "1" }} }));
}

test "subscribe before connect is Disconnected, after close ConnectionClosed" {
    var client: Client = try .init(testing.allocator, testing.io, .{ .servers = one_server });
    defer client.deinit();
    try testing.expectError(error.Disconnected, client.subscribe("foo", .{}));
    // The arguments are checked first, whatever the state.
    try testing.expectError(error.InvalidSubject, client.subscribe("foo bar", .{}));
    try testing.expectError(error.InvalidOptions, client.subscribe("foo", .{ .queue = "two words" }));
    client.close();
    try testing.expectError(error.ConnectionClosed, client.subscribe("foo", .{}));
}

test "a message fits when it is within max_payload, or nine digits when that is unknown" {
    try testing.expect(fitsPayload(1024, 1024));
    try testing.expect(!fitsPayload(1025, 1024));
    try testing.expect(fitsPayload(0, 1024));
    // 0: the server did not say.
    try testing.expect(fitsPayload(999_999_999, 0));
    try testing.expect(!fitsPayload(1_000_000_000, 0));
    try testing.expect(!fitsPayload(1_000_000_000, 2_000_000_000));
}

test "connect needs an io with concurrency" {
    var single: Io.Threaded = .init_single_threaded;
    var client: Client = try .init(testing.allocator, single.io(), .{ .servers = one_server });
    defer client.deinit();
    try testing.expectError(error.ConcurrencyUnavailable, client.connect());
    try testing.expectEqual(.closed, client.state());
}
