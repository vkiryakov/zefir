//! One connection to the server, in the heap: the reader and the writer of
//! its stream point into it. It holds one exchange at a time, a request
//! and its reply, under the deadline of the exchange. A connection that
//! broke the protocol, timed out, lost its stream, was cut or was
//! canceled in the middle of an exchange is no longer `usable`: its owner
//! destroys it. The pool keeps it through its `pooled` entry.

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const Allocator = std.mem.Allocator;
const core = @import("core");
const mongo = @import("../root.zig");
const bson = mongo.bson;
const wire = @import("../wire.zig");
const opmsg = wire.opmsg;
const Diagnostics = mongo.Diagnostics;
const DeadlineStream = @import("DeadlineStream.zig");
const Pool = @import("Pool.zig");
const Connection = @This();

gpa: Allocator,
/// The server, for messages.
address: Address,
stream: DeadlineStream,
/// What the server said about itself in hello: its limits and its id of
/// the connection. Before hello, the defaults of a standalone mongod: a
/// reply may be 48 000 000 bytes at most.
hello: wire.Hello = .{},
/// The round trip of hello.
rtt: ?Io.Duration = null,
/// The requestID of the next request; it wraps around.
next_id: i32 = 1,
/// False after an exchange that left the stream unusable.
usable: bool = true,
/// The pool's part of the connection.
pooled: Pool.Entry = .{ .hooks = &pool_hooks },
read_buffer: [buffer_len]u8,
write_buffer: [buffer_len]u8,

const buffer_len = 16 * 1024;

/// The host and the port of a server.
pub const Address = struct {
    host: []const u8,
    port: u16,

    /// "host:port", or "[::1]:port" for an IPv6 address.
    pub fn format(a: Address, w: *Io.Writer) Io.Writer.Error!void {
        if (std.mem.findScalar(u8, a.host, ':') != null) return w.print("[{s}]:{d}", .{ a.host, a.port });
        return w.print("{s}:{d}", .{ a.host, a.port });
    }
};

/// A connection over `stream`, which it owns from now on. `address` must
/// outlive it.
pub fn create(gpa: Allocator, io: Io, stream: net.Stream, address: Address) Allocator.Error!*Connection {
    const conn = try gpa.create(Connection);
    conn.* = .{ .gpa = gpa, .address = address, .stream = undefined, .read_buffer = undefined, .write_buffer = undefined };
    conn.stream.init(io, stream, &conn.read_buffer, &conn.write_buffer);
    return conn;
}

/// Closes the socket and frees the connection.
pub fn destroy(conn: *Connection) void {
    conn.stream.stream.close(conn.stream.io);
    conn.gpa.destroy(conn);
}

/// The connection of a pool's entry.
pub fn of(entry: *Pool.Entry) *Connection {
    return @alignCast(@fieldParentPtr("pooled", entry));
}

const pool_hooks: Pool.Entry.Hooks = .{ .destroy = destroyEntry, .cut = cutEntry };

fn destroyEntry(entry: *Pool.Entry) void {
    of(entry).destroy();
}

fn cutEntry(entry: *Pool.Entry, io: Io) void {
    of(entry).cut(io);
}

/// Cuts the exchange in progress from another task, and every later one:
/// they fail with `error.ConnectionLost` at once. `destroy` still closes
/// the socket.
pub fn cut(conn: *Connection, io: Io) void {
    conn.stream.cut(io, .stop);
}

/// A request, as `wire.opmsg.Request` without its requestID.
pub const Request = struct {
    database: []const u8,
    body: bson.RawDocument,
    ordered: ?bool = null,
    max_time_ms: ?i64 = null,
    sequence: ?opmsg.Sequence = null,
};

/// Sends `request` and returns the reply, from `allocator`, waiting no
/// longer than `deadline`. The errors are the contract's: a request that
/// cannot go out is `InvalidArgument` and the connection stays usable;
/// after the request started to go out, a lost stream is `ConnectionLost`,
/// the deadline `Timeout`, a canceled task `Interrupted` (and the task is
/// canceled again), a reply that breaks OP_MSG `ProtocolViolation`, and
/// the connection is no longer usable. `ok: 0` is the caller's to check.
pub fn exchange(conn: *Connection, request: Request, allocator: Allocator, deadline: ?core.Deadline, d: ?*Diagnostics) mongo.Error!bson.OwnedDocument {
    const message: opmsg.Request = .{
        .request_id = conn.next_id,
        .body = request.body,
        .database = request.database,
        .ordered = request.ordered,
        .max_time_ms = request.max_time_ms,
        .sequence = request.sequence,
    };
    const limit = conn.hello.max_message_size_bytes;
    if (message.length() > limit) return fail(d, .send, error.InvalidArgument, "the command is {d} bytes as OP_MSG, and the server takes {d} at most", .{ message.length(), limit });
    conn.next_id +%= 1;
    conn.stream.begin(deadline);
    opmsg.writeRequest(&conn.stream.writer, message) catch |err| switch (err) {
        // writeRequest checks before it writes anything.
        error.InvalidArgument => return fail(d, .send, error.InvalidArgument, "the command cannot be written as OP_MSG", .{}),
        error.WriteFailed => return conn.broken(d, .send),
    };
    conn.stream.writer.flush() catch return conn.broken(d, .send);
    return opmsg.readReply(&conn.stream.reader, allocator, .{ .request_id = message.request_id, .max_message_size = limit }, d) catch |err| switch (err) {
        // The rest of the reply is still on the stream.
        error.ProtocolViolation, error.OutOfMemory => |e| {
            conn.usable = false;
            return e;
        },
        error.ReadFailed, error.EndOfStream => conn.broken(d, .wait),
    };
}

/// The error of an exchange whose stream failed.
fn broken(conn: *Connection, d: ?*Diagnostics, phase: Diagnostics.Phase) mongo.Error {
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

fn fail(d: ?*Diagnostics, phase: Diagnostics.Phase, err: mongo.Error, comptime fmt: []const u8, args: anytype) mongo.Error {
    if (d) |x| x.set(phase, null, fmt, args);
    return err;
}

test "an address prints as host:port, an IPv6 one in brackets" {
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("db.example.com:27017", try std.fmt.bufPrint(&buffer, "{f}", .{Address{ .host = "db.example.com", .port = 27017 }}));
    try std.testing.expectEqualStrings("[::1]:27018", try std.fmt.bufPrint(&buffer, "{f}", .{Address{ .host = "::1", .port = 27018 }}));
}
