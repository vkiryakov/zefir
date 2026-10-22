//! One connection to the server, in the heap: the reader and the writer of
//! its stream point into it. It holds one exchange at a time, under the
//! deadline of the exchange: commands written into its buffer of 16 KiB,
//! sent at one flush, and their replies, read in order through the command
//! types' own decoders.
//!
//! - `exchange` sends one command and reads its reply. A pipeline is
//!   `begin`, `write` for each command, one `flush`, then `receive` for
//!   each reply.
//! - A reply that does not fit the type the call named (`UnexpectedReply`)
//!   and an error of the server (`ServerError`) leave the connection
//!   usable: the reply was read to its end.
//! - After a lost stream (`ConnectionLost`), a deadline (`Timeout`), a
//!   canceled task (`Interrupted`), a reply that breaks RESP3
//!   (`ProtocolViolation`) or one too large (`ReplyTooLarge`), or memory
//!   that ran out, the connection is no longer `usable`: what is left of
//!   the reply is still on the stream, and its owner destroys it.
//! - The pushes that a server sends between replies are skipped, with the
//!   attributes before them, and logged at debug: they do not knock the
//!   replies out of their order.
//!
//! The pool keeps it through its `pooled` entry.

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const Allocator = std.mem.Allocator;
const core = @import("core");
const resp = @import("../resp.zig");
const cmd = @import("../cmd.zig");
const errors = @import("../errors.zig");
const Diagnostics = errors.Diagnostics;
const Address = @import("Address.zig");
const DeadlineStream = @import("DeadlineStream.zig");
const Pool = @import("Pool.zig");
const time = @import("time.zig");
const log = std.log.scoped(.redis);
const Connection = @This();

gpa: Allocator,
/// The server, for messages.
address: Address,
stream: DeadlineStream,
/// The most bytes one reply may take on the wire.
max_reply_bytes: usize,
/// The number of the connection on the server, from HELLO.
id: ?i64 = null,
/// The round trip of HELLO.
rtt: ?Io.Duration = null,
/// False after an exchange that left the stream unusable.
usable: bool = true,
/// The pool's part of the connection.
pooled: Pool.Entry = .{ .hooks = &pool_hooks },
read_buffer: [buffer_len]u8,
write_buffer: [buffer_len]u8,

/// The size of each buffer. A double of RESP3 must fit the read buffer
/// whole, and a server sends one of a few kilobytes at most.
pub const buffer_len = 16 * 1024;

pub const Error = errors.Error;

/// A connection over `stream`, which it owns from now on. `address` must
/// outlive it.
pub fn create(gpa: Allocator, io: Io, stream: net.Stream, address: Address, max_reply_bytes: usize) Allocator.Error!*Connection {
    const conn = try gpa.create(Connection);
    conn.* = .{
        .gpa = gpa,
        .address = address,
        .stream = undefined,
        .max_reply_bytes = max_reply_bytes,
        .read_buffer = undefined,
        .write_buffer = undefined,
    };
    conn.stream.init(io, stream, &conn.read_buffer, &conn.write_buffer);
    return conn;
}

/// Closes the socket and frees the connection.
pub fn destroy(conn: *Connection) void {
    conn.stream.stream.close(conn.stream.io);
    conn.gpa.destroy(conn);
}

/// Cuts the exchange in progress from another task, and every later one:
/// they fail with `error.ConnectionLost` at once. `destroy` still closes
/// the socket.
pub fn cut(conn: *Connection, io: Io) void {
    conn.stream.cut(io, .stop);
}

/// The connection of a pool's entry.
pub fn of(entry: *Pool.Entry) *Connection {
    return @alignCast(@fieldParentPtr("pooled", entry));
}

const pool_hooks: Pool.Entry.Hooks = .{ .destroy = destroyEntry, .cut = cutEntry, .ping = pingEntry };

fn destroyEntry(entry: *Pool.Entry) void {
    of(entry).destroy();
}

fn cutEntry(entry: *Pool.Entry, io: Io) void {
    of(entry).cut(io);
}

/// PING on a connection that lay idle. Any reply means the server is
/// there, an error too: LOADING and BUSY refuse PING.
fn pingEntry(entry: *Pool.Entry, io: Io, deadline: ?core.Deadline) Pool.Liveness {
    _ = io;
    var d: Diagnostics = .{};
    of(entry).exchange(cmd.raw(void, .{"PING"}), null, deadline, &d) catch |err| return switch (err) {
        error.ServerError, error.UnexpectedReply => .alive,
        error.Timeout => .deadline,
        // The task stays canceled.
        error.Interrupted => .canceled,
        else => .dead,
    };
    return .alive;
}

/// Sends `command` and reads its reply, from `arena`, waiting no longer
/// than `deadline`; null: no limit. The caller has checked the command.
pub fn exchange(conn: *Connection, command: anytype, arena: ?Allocator, deadline: ?core.Deadline, d: ?*Diagnostics) Error!@TypeOf(command).Reply {
    conn.begin(deadline);
    try conn.write(command, d);
    try conn.flush(d);
    return conn.receive(command, arena, d);
}

/// Starts an exchange that must end by `deadline`; null: no limit.
pub fn begin(conn: *Connection, deadline: ?core.Deadline) void {
    conn.stream.begin(deadline);
}

/// Writes `command` into the buffer: nothing goes out before `flush`,
/// but what does not fit the buffer.
pub fn write(conn: *Connection, command: anytype, d: ?*Diagnostics) Error!void {
    command.write(.init(&conn.stream.writer)) catch return conn.broken(d, .send);
}

/// Writes the blocking `command` with `timeout_ms` in place of its own
/// timeout, 0 for forever.
pub fn writeWith(conn: *Connection, command: anytype, timeout_ms: u64, d: ?*Diagnostics) Error!void {
    command.writeWith(.init(&conn.stream.writer), timeout_ms) catch return conn.broken(d, .send);
}

/// Sends what was written.
pub fn flush(conn: *Connection, d: ?*Diagnostics) Error!void {
    conn.stream.writer.flush() catch return conn.broken(d, .send);
}

/// Reads the next reply on the stream as the reply of `command`, from
/// `arena`. A reply read to its end sets the idle clock of the pool's
/// entry: a connection idles from its last reply, whoever holds it.
pub fn receive(conn: *Connection, command: anytype, arena: ?Allocator, d: ?*Diagnostics) Error!@TypeOf(command).Reply {
    conn.skipPushes() catch |err| return conn.failed(err, d, .wait);
    var reader: resp.Reader = .init(&conn.stream.reader, conn.max_reply_bytes);
    const reply = command.read(&reader, arena, d) catch |err| switch (err) {
        error.ServerError, error.UnexpectedReply => |e| {
            conn.pooled.idle_since = time.now(conn.stream.io);
            return e;
        },
        error.OutOfMemory => {
            conn.usable = false;
            return error.OutOfMemory;
        },
        error.ProtocolViolation, error.ReplyTooLarge, error.ReadFailed, error.EndOfStream => |e| return conn.failed(e, d, .receive),
    };
    conn.pooled.idle_since = time.now(conn.stream.io);
    return reply;
}

/// Skips the pushes before the next reply, with the attributes before
/// them: a server sends a push between replies, never inside one.
fn skipPushes(conn: *Connection) resp.Reader.Error!void {
    while (true) {
        var reader: resp.Reader = .init(&conn.stream.reader, conn.max_reply_bytes);
        try reader.skipAttributes();
        if (try conn.stream.reader.peekByte() != '>') return;
        const push = try reader.next();
        try reader.skipReply();
        log.debug("skipped a push of {d} elements from {f} between replies", .{ push.push, conn.address });
    }
}

/// The error of an exchange whose reading failed in `phase`.
pub fn failed(conn: *Connection, err: resp.Reader.Error, d: ?*Diagnostics, phase: Diagnostics.Phase) Error {
    switch (err) {
        error.ReadFailed, error.EndOfStream => return conn.broken(d, phase),
        error.ProtocolViolation => {
            conn.usable = false;
            return fail(d, .receive, error.ProtocolViolation, "the reply broke RESP3", .{});
        },
        error.ReplyTooLarge => {
            conn.usable = false;
            return fail(d, .receive, error.ReplyTooLarge, "the reply is larger than max_reply_bytes ({d}) or nests deeper than {d} levels", .{ conn.max_reply_bytes, resp.Reader.max_depth });
        },
    }
}

/// The error of an exchange whose stream failed.
fn broken(conn: *Connection, d: ?*Diagnostics, phase: Diagnostics.Phase) Error {
    conn.usable = false;
    // The end of the stream, or a reset: the server closed it.
    const closed = if (conn.stream.err) |cause| cause == error.ConnectionResetByPeer else true;
    if (closed) {
        if (d) |x| x.set(phase, conn.stream.err, "the server at {f} closed the connection", .{conn.address});
        return error.ConnectionLost;
    }
    const cause = conn.stream.err.?;
    switch (cause) {
        error.Timeout => return switch (phase) {
            .send => fail(d, phase, error.Timeout, "the deadline passed while the command went out", .{}),
            else => fail(d, phase, error.Timeout, "the deadline passed before the reply came", .{}),
        },
        error.Canceled => {
            conn.stream.io.recancel();
            return fail(d, phase, error.Interrupted, "the task was canceled while the command was out", .{});
        },
        error.Stopped => return fail(d, phase, error.ConnectionLost, "the exchange was cut", .{}),
        else => {
            if (d) |x| x.set(phase, cause, "the connection to {f} broke: {t}", .{ conn.address, cause });
            return error.ConnectionLost;
        },
    }
}

fn fail(d: ?*Diagnostics, phase: Diagnostics.Phase, err: Error, comptime fmt: []const u8, args: anytype) Error {
    if (d) |x| x.set(phase, null, fmt, args);
    return err;
}
