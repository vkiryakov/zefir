//! What `redis.Subscriber` is made of, internal to the module: the state
//! of a subscriber in the heap, the subscription on a connection of its
//! own, and the frames that come on it. The client keeps a `Registry` of
//! its subscribers, for its `stats`.
//!
//! A frame on a subscriber's connection is a push, a message or the
//! confirmation of a subscription; or a reply, which only the subscriber's
//! own PING gets; or an error. The server sends a message only after the
//! command that subscribed is done, but between two commands, SUBSCRIBE
//! and PSUBSCRIBE, it may send one, which the subscription keeps for the
//! first `next`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const core = @import("core");
const errors = @import("../errors.zig");
const Error = errors.Error;
const Diagnostics = errors.Diagnostics;
const requests = @import("../requests.zig");
const OperationContext = requests.OperationContext;
const SubscribeOptions = requests.SubscribeOptions;
const resp = @import("../resp.zig");
const calls = @import("../calls.zig");
const Client = @import("../Client.zig");
const Message = @import("../Subscriber.zig").Message;
const Connection = @import("Connection.zig");
const connect_ = @import("connect.zig");
const List = std.DoublyLinkedList;

/// A subscriber, in the heap: the client reaches it here, from another
/// task than the subscriber's.
pub const State = struct {
    /// In the client's `Registry`.
    node: List.Node = .{},
    gpa: Allocator,
    /// The connection, once its handshake is done; `destroy` closes it.
    conn: ?*Connection = null,
    /// The opening of the connection.
    attempt: connect_.Attempt = .{},
    /// Counted in `Registry.open`: `subscribe` returned it.
    counted: bool = false,
    idle_ping: Io.Duration,
    /// The messages that came between the confirmations, for the first
    /// calls of `next`: where each lies in `early_bytes`, and how many of
    /// them `next` gave.
    early: std.ArrayList(Parts) = .empty,
    early_bytes: std.ArrayList(u8) = .empty,
    early_given: usize = 0,

    /// Closes the connection and frees the state.
    pub fn destroy(state: *State) void {
        if (state.conn) |conn| conn.destroy();
        state.early.deinit(state.gpa);
        state.early_bytes.deinit(state.gpa);
        state.gpa.destroy(state);
    }

    /// Waits for the confirmation of `name`, a channel or a pattern as
    /// `kind` says, through the frames that come before it: a message
    /// goes to `early`, a push of another kind is skipped. An error of the
    /// server is `error.ServerError`.
    fn awaitConfirmation(state: *State, conn: *Connection, kind: Kind, name: []const u8, d: ?*Diagnostics) Error!void {
        while (true) {
            var reader: resp.Reader = .init(&conn.stream.reader, conn.max_reply_bytes);
            const mark = state.early_bytes.items.len;
            const frame = readFrame(&reader, &state.early_bytes, state.gpa, d) catch |err| return confirmationFailed(conn, err, d);
            switch (frame) {
                .message => |parts| try state.early.append(state.gpa, parts),
                .confirmed => |confirmed| {
                    const got = state.early_bytes.items[mark..];
                    defer state.early_bytes.shrinkRetainingCapacity(mark);
                    if (confirmed != kind or !std.mem.eql(u8, got, name)) {
                        conn.usable = false;
                        return calls.fail(d, .receive, error.ProtocolViolation, "the server confirmed another subscription than the one the subscriber asked for, in its place", .{});
                    }
                    return;
                },
                .refused => return error.ServerError,
                .reply => {
                    conn.usable = false;
                    return calls.fail(d, .receive, error.ProtocolViolation, "the server answered the subscription with a reply, where a push of its confirmation was due", .{});
                },
                .other => state.early_bytes.shrinkRetainingCapacity(mark),
            }
        }
    }
};

/// The subscribers of a client, each from the start of its `subscribe`
/// until its `close`.
pub const Registry = struct {
    mutex: Io.Mutex = .init,
    list: List = .{},
    /// How many of them `subscribe` returned.
    open: usize = 0,

    /// Registers `state`.
    fn add(r: *Registry, io: Io, state: *State) void {
        r.mutex.lockUncancelable(io);
        defer r.mutex.unlock(io);
        r.list.append(&state.node);
    }

    /// Counts `state`, which `subscribe` returns.
    fn opened(r: *Registry, io: Io, state: *State) void {
        r.mutex.lockUncancelable(io);
        defer r.mutex.unlock(io);
        state.counted = true;
        r.open += 1;
    }

    /// Unregisters `state`, which `close` is about to free.
    pub fn remove(r: *Registry, io: Io, state: *State) void {
        r.mutex.lockUncancelable(io);
        defer r.mutex.unlock(io);
        r.list.remove(&state.node);
        if (state.counted) r.open -= 1;
    }

    /// How many subscribers `subscribe` returned and `close` has not
    /// freed.
    pub fn count(r: *Registry, io: Io) usize {
        r.mutex.lockUncancelable(io);
        defer r.mutex.unlock(io);
        return r.open;
    }
};

/// The subscription of `client.subscribe`: a connection of its own with
/// the handshake of the pool's, SUBSCRIBE and PSUBSCRIBE in one write and
/// the confirmation of each name, all within the deadline of `op`, else
/// `timeout` from now. Any error leaves nothing behind: the connection is
/// closed.
pub fn subscribe(c: *Client, io: Io, op: OperationContext, options: SubscribeOptions) Error!*State {
    calls.checkUse(c, io);
    const d = options.diagnostics;
    if (d) |x| x.* = .{};
    try check(options, d);
    try calls.checkContext(io, op, d);
    try c.pool.enter(io, d);
    defer c.pool.leave(io);
    if (!c.pool.isConnected(io)) return calls.fail(d, .checkout, error.Unavailable, "connect() has not succeeded", .{});
    const deadline = calls.deadlineOf(c, io, op, .none);
    const state = try c.gpa.create(State);
    state.* = .{ .gpa = c.gpa, .idle_ping = options.idle_ping };
    c.subscribers.add(io, state);
    errdefer {
        c.subscribers.remove(io, state);
        state.destroy();
    }
    state.conn = try calls.open(c, io, deadline, &state.attempt, d);
    try confirm(c, state, state.conn.?, io, op, options, deadline, d);
    c.subscribers.opened(io, state);
    return state;
}

/// The rules of the options: a name at least, and an `idle_ping` of 1 ms
/// or more that the client counts in milliseconds.
fn check(options: SubscribeOptions, d: ?*Diagnostics) Error!void {
    const call = "redis.Client.subscribe";
    if (options.channels.len == 0 and options.patterns.len == 0) {
        return calls.fail(d, null, error.InvalidArgument, call ++ ": no channels and no patterns: give one or more", .{});
    }
    const idle = options.idle_ping.nanoseconds;
    if (idle < std.time.ns_per_ms) return calls.fail(d, null, error.InvalidArgument, call ++ ": .idle_ping is under 1 ms: give 1 ms or more", .{});
    if (@divTrunc(idle, std.time.ns_per_ms) > std.math.maxInt(i64)) {
        return calls.fail(d, null, error.InvalidArgument, call ++ ": .idle_ping is longer than {d} ms, the most the client counts", .{std.math.maxInt(i64)});
    }
}

/// SUBSCRIBE and PSUBSCRIBE, those that have names, in one write, then the
/// confirmation of each name in their order.
fn confirm(c: *Client, state: *State, conn: *Connection, io: Io, op: OperationContext, options: SubscribeOptions, deadline: ?core.Deadline, d: ?*Diagnostics) Error!void {
    try calls.beforeSend(c, io, op, deadline, d);
    conn.begin(deadline);
    if (options.channels.len > 0) try conn.write(Subscribe{ .word = "SUBSCRIBE", .names = options.channels }, d);
    if (options.patterns.len > 0) try conn.write(Subscribe{ .word = "PSUBSCRIBE", .names = options.patterns }, d);
    try conn.flush(d);
    for (options.channels) |name| try state.awaitConfirmation(conn, .channel, name, d);
    for (options.patterns) |name| try state.awaitConfirmation(conn, .pattern, name, d);
}

/// SUBSCRIBE or PSUBSCRIBE with its names.
const Subscribe = struct {
    word: []const u8,
    names: []const []const u8,

    pub fn write(s: Subscribe, w: resp.Writer) resp.Writer.Error!void {
        try w.arrayHeader(1 + s.names.len);
        try w.bulk(s.word);
        for (s.names) |name| try w.bulk(name);
    }
};

/// The error of a read that failed while the subscription waited for its
/// confirmations.
fn confirmationFailed(conn: *Connection, err: FrameError, d: ?*Diagnostics) Error {
    switch (err) {
        error.OutOfMemory => {
            conn.usable = false;
            return error.OutOfMemory;
        },
        error.ReadFailed, error.EndOfStream, error.ProtocolViolation, error.ReplyTooLarge => |e| {
            if (conn.stream.err) |cause| if (e == error.ReadFailed and cause == error.Timeout) {
                conn.usable = false;
                return calls.fail(d, .receive, error.Timeout, "the deadline passed before the server confirmed the subscription", .{});
            };
            return conn.failed(e, d, .receive);
        },
    }
}

/// A channel of SUBSCRIBE or a pattern of PSUBSCRIBE.
pub const Kind = enum { channel, pattern };

/// Where a part of a frame lies in the bytes it was read into.
pub const Span = struct {
    start: usize,
    len: usize,

    fn of(s: Span, bytes: []const u8) []const u8 {
        return bytes[s.start..][0..s.len];
    }
};

/// Where the parts of a message lie.
pub const Parts = struct {
    channel: Span,
    payload: Span,
    pattern: ?Span = null,

    /// The message of these parts in `bytes`.
    pub fn of(p: Parts, bytes: []const u8) Message {
        return .{
            .channel = p.channel.of(bytes),
            .payload = p.payload.of(bytes),
            .pattern = if (p.pattern) |pattern| pattern.of(bytes) else null,
        };
    }
};

/// What a frame on a subscriber's connection was.
pub const Frame = union(enum) {
    /// A message, its parts in the bytes it was read into.
    message: Parts,
    /// The confirmation of a channel or a pattern, its name at the end of
    /// the bytes it was read into.
    confirmed: Kind,
    /// A reply to a command: the subscriber's PING gets one.
    reply,
    /// An error of the server, its text in the diagnostics.
    refused,
    /// A push of another kind, which the subscriber skips.
    other,
};

pub const FrameError = resp.Reader.Error || Allocator.Error;

/// Reads one frame through `r`, the strings of a message or of a
/// confirmation into `out`, from `gpa`.
pub fn readFrame(r: *resp.Reader, out: *std.ArrayList(u8), gpa: Allocator, d: ?*Diagnostics) FrameError!Frame {
    switch (try r.next()) {
        .push => |n| {
            if (n == 0) return .other;
            var buffer: [16]u8 = undefined;
            const kind = try wordOf(r, try r.next(), &buffer);
            if (n == 3 and std.mem.eql(u8, kind, "message")) {
                const channel = try appendString(r, out, gpa);
                return .{ .message = .{ .channel = channel, .payload = try appendString(r, out, gpa) } };
            }
            if (n == 4 and std.mem.eql(u8, kind, "pmessage")) {
                const pattern = try appendString(r, out, gpa);
                const channel = try appendString(r, out, gpa);
                return .{ .message = .{ .channel = channel, .payload = try appendString(r, out, gpa), .pattern = pattern } };
            }
            if (n == 3) if (confirmationOf(kind)) |confirmed| {
                _ = try appendString(r, out, gpa);
                if (try r.next() != .integer) return error.ProtocolViolation;
                return .{ .confirmed = confirmed };
            };
            try r.skipReply();
            return .other;
        },
        .simple_error, .bulk_error => {
            // As much as Diagnostics keeps of a text.
            var text: [512]u8 = undefined;
            const prefix = try r.payloadPrefix(&text);
            if (d) |x| x.setServer(.receive, prefix.bytes);
            return .refused;
        },
        else => {
            try r.skipReply();
            return .reply;
        },
    }
}

/// The kind of a push, its first element: a string of at most 16 bytes,
/// else "", which no push of a subscriber's has.
fn wordOf(r: *resp.Reader, element: resp.Reader.Element, buffer: *[16]u8) resp.Reader.Error![]const u8 {
    switch (element) {
        .simple_string, .bulk_string, .verbatim_string => {
            const prefix = try r.payloadPrefix(buffer);
            return if (prefix.len == prefix.bytes.len) prefix.bytes else "";
        },
        else => return "",
    }
}

fn confirmationOf(kind: []const u8) ?Kind {
    if (std.mem.eql(u8, kind, "subscribe")) return .channel;
    if (std.mem.eql(u8, kind, "psubscribe")) return .pattern;
    return null;
}

/// Reads the string that comes next through `r` to the end of `out`, and
/// returns where it lies there: anything but a string is a
/// ProtocolViolation.
fn appendString(r: *resp.Reader, out: *std.ArrayList(u8), gpa: Allocator) FrameError!Span {
    switch (try r.next()) {
        // The reader checked the length against max_reply_bytes.
        .bulk_string => |len| try out.ensureUnusedCapacity(gpa, len),
        .verbatim_string => |verbatim| try out.ensureUnusedCapacity(gpa, verbatim.len),
        .simple_string => {},
        else => return error.ProtocolViolation,
    }
    const start = out.items.len;
    while (try r.payloadChunk()) |piece| try out.appendSlice(gpa, piece);
    return .{ .start = start, .len = out.items.len - start };
}
