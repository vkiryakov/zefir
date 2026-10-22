//! The replies of `redis.testing.FakeServer`: what a step or a handler
//! answers a command with, and their bytes in RESP3.
//!
//! - `Reply` — data in RESP3, an error, bytes as they are, bytes that
//!   break RESP3, or an action of the server: a reply after a delay, a
//!   closed connection, a server that goes away.
//! - `write(w, reply)` — the bytes of a reply into `w`, as a Redis server
//!   writes them; the server flushes them.

const std = @import("std");
const Io = std.Io;
const resp = @import("../resp.zig");

/// What the server answers a command with.
///
/// The data variants are the kinds of RESP3 a server sends: `.ok` is
/// `+OK`, `.nil` is the null `_`, `.string` a bulk string, `.pairs` a map
/// in the order given. Strings are bytes, `\r\n` and `\x00` included. An
/// aggregate holds replies of its own: `.{ .array = &.{ .ok, .nil } }`. A
/// kind that has no variant of its own, a simple string other than `OK`,
/// a big number, a verbatim string, an attribute, goes as `.raw` bytes.
///
/// The actions, `delayed`, `close_connection` and `refuse_connections`,
/// act on a whole reply: inside an aggregate there is nothing to delay or
/// close, and `write` puts an error in their place.
pub const Reply = union(enum) {
    /// `+OK`.
    ok,
    /// `_`, the null of RESP3.
    nil,
    integer: i64,
    /// A bulk string.
    string: []const u8,
    /// A double, in its shortest text: `12.5`, `inf`, `-inf`, `nan`.
    double: f64,
    boolean: bool,
    array: []const Reply,
    set: []const Reply,
    /// A map: its keys and values, in this order.
    pairs: []const [2]Reply,
    /// Data the server sends on its own, such as a message to a
    /// subscriber.
    push: []const Reply,
    /// An error, its code first, as one line of text:
    /// `.{ .err = "WRONGTYPE Operation against a key holding the wrong kind of value" }`.
    err: []const u8,
    /// A reply after a pause, never sooner: for deadlines, cancelation and
    /// closing.
    delayed: Delayed,
    /// Read the command and close the connection without a reply.
    close_connection,
    /// Close every connection of the server without a reply, and refuse
    /// new connections until the test accepts them again: the server went
    /// away.
    refuse_connections,
    /// A reply that breaks RESP3.
    malformed: Malformed,
    /// Bytes as they are.
    raw: []const u8,

    /// A map of strings to strings, in the order given, as HGETALL answers:
    /// `.map(&.{ .{ "name", "Ann" }, .{ "age", "30" } })`.
    pub fn map(comptime pairs: []const [2][]const u8) Reply {
        const items = comptime items: {
            var out: [pairs.len][2]Reply = undefined;
            for (pairs, &out) |pair, *slot| slot.* = .{ .{ .string = pair[0] }, .{ .string = pair[1] } };
            break :items out;
        };
        return .{ .pairs = &items };
    }

    /// The confirmations of SUBSCRIBE: a push for each channel, in the
    /// order given, with the number of channels subscribed so far:
    /// `>3 subscribe orders 1`, then `>3 subscribe news 2`.
    pub fn subscribed(comptime channels: []const []const u8) Reply {
        if (channels.len == 0) @compileError("redis.testing.FakeServer.Reply.subscribed: no channels: SUBSCRIBE confirms each channel it names");
        const bytes = comptime bytes: {
            var out: []const u8 = "";
            for (channels, 1..) |channel, n| {
                out = out ++ std.fmt.comptimePrint(">3\r\n$9\r\nsubscribe\r\n${d}\r\n", .{channel.len}) ++
                    channel ++ std.fmt.comptimePrint("\r\n:{d}\r\n", .{n});
            }
            break :bytes out;
        };
        return .{ .raw = bytes };
    }

    /// A message to a subscriber of `channel`: the push
    /// `["message", channel, payload]`.
    pub fn message(comptime channel: []const u8, comptime payload: []const u8) Reply {
        const items = comptime [_]Reply{ .{ .string = "message" }, .{ .string = channel }, .{ .string = payload } };
        return .{ .push = &items };
    }
};

pub const Delayed = struct {
    /// How long the server waits, on the awake clock. `Io.Duration.max`
    /// waits until the server stops: the reply never comes.
    after: Io.Duration,
    /// What it does then: any reply, an action included.
    reply: *const Reply,
};

/// How a malformed reply breaks RESP3. The client takes the first two as a
/// protocol violation; the server leaves the connection open after them,
/// so that a client that used it again would show in the journal.
pub const Malformed = enum {
    /// `@1\r\n`: a byte that starts no kind of RESP3.
    unknown_type,
    /// `$-2\r\n`: a bulk string whose length is no length; only `-1`, the
    /// null of RESP2, is below 0.
    bad_length,
    /// `*2\r\n$3\r\nAnn\r\n`, an array of two whose second element never
    /// comes: the server closes the connection after it, and the stream
    /// ends inside the reply.
    truncated,

    /// The bytes of the defect.
    pub fn bytes(defect: Malformed) []const u8 {
        return switch (defect) {
            .unknown_type => "@1\r\n",
            .bad_length => "$-2\r\n",
            .truncated => "*2\r\n$3\r\nAnn\r\n",
        };
    }
};

/// Writes the bytes of `reply` into `w`. An action inside an aggregate is
/// written as an error in its place, so that the reply stays whole.
pub fn write(w: *Io.Writer, reply: Reply) Io.Writer.Error!void {
    switch (reply) {
        .ok => try w.writeAll("+OK\r\n"),
        .nil => try w.writeAll("_\r\n"),
        .integer => |n| try w.print(":{d}\r\n", .{n}),
        .string => |bytes| {
            try w.print("${d}\r\n", .{bytes.len});
            try w.writeAll(bytes);
            try w.writeAll("\r\n");
        },
        .double => |x| try writeDouble(w, x),
        .boolean => |b| try w.writeAll(if (b) "#t\r\n" else "#f\r\n"),
        .array => |items| try writeAggregate(w, '*', items),
        .set => |items| try writeAggregate(w, '~', items),
        .push => |items| try writeAggregate(w, '>', items),
        .pairs => |pairs| {
            try w.print("%{d}\r\n", .{pairs.len});
            for (pairs) |pair| {
                try write(w, pair[0]);
                try write(w, pair[1]);
            }
        },
        .err => |text| {
            try w.writeByte('-');
            try w.writeAll(text);
            try w.writeAll("\r\n");
        },
        .raw => |bytes| try w.writeAll(bytes),
        .malformed => |defect| try w.writeAll(defect.bytes()),
        .delayed => try writeAction(w, "a delayed reply"),
        .close_connection => try writeAction(w, "close_connection"),
        .refuse_connections => try writeAction(w, "refuse_connections"),
    }
}

fn writeAggregate(w: *Io.Writer, kind: u8, items: []const Reply) Io.Writer.Error!void {
    try w.print("{c}{d}\r\n", .{ kind, items.len });
    for (items) |item| try write(w, item);
}

fn writeDouble(w: *Io.Writer, x: f64) Io.Writer.Error!void {
    var buffer: [resp.args.float_buffer_len]u8 = undefined;
    try w.writeByte(',');
    try w.writeAll(resp.args.formatFloat(&buffer, x));
    try w.writeAll("\r\n");
}

fn writeAction(w: *Io.Writer, comptime action: []const u8) Io.Writer.Error!void {
    try w.writeAll("-ERR zefir FakeServer: " ++ action ++ " inside an aggregate: delays, closing and refusing act on a whole reply\r\n");
}
