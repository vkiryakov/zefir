//! Reads and writes on the socket of a connection, each within its time:
//! `io.operateTimeout`, where the runtime runs one operation with a timer
//! of its own and no task more (the probes of tests/http checked it on
//! zio on Linux, macOS and Windows). Internal to `http.native`.

const std = @import("std");
const core = @import("core");
const waiting = @import("../wait.zig");

const net = std.Io.net;

pub const ReadError = error{
    /// The awake clock passed the deadline before anything came.
    Timeout,
    /// A broken connection: reset, or an error of the system.
    ReadFailed,
} || std.Io.Cancelable;

/// One read of what has arrived into `buffer`, which is not empty, waiting
/// for something until `deadline`; null waits without a limit. 0: the
/// peer ended its side of the connection. `error.Timeout` only once the
/// deadline has passed: a far deadline is waited for in steps, and a timer
/// that fires early reads again.
pub fn read(io: std.Io, stream: net.Stream, buffer: []u8, deadline: ?core.Deadline) ReadError!usize {
    std.debug.assert(buffer.len > 0); // an empty read would look like the end of the stream
    var data: [1][]u8 = .{buffer};
    const operation: std.Io.Operation = .{ .net_read = .{ .socket_handle = stream.socket.handle, .data = &data } };
    const limit = deadline orelse {
        const result = try io.operate(operation);
        return (result.net_read catch return error.ReadFailed).data_len;
    };
    while (true) {
        const now = std.Io.Clock.awake.now(io);
        if (limit.isExpired(now)) return error.Timeout;
        const step = limit.earliest(.after(now, waiting.max_step));
        const result = io.operateTimeout(operation, step.toTimeout()) catch |err| switch (err) {
            error.Timeout => continue,
            error.Canceled => |e| return e,
            error.ConcurrencyUnavailable => return error.ReadFailed,
        };
        return (result.net_read catch return error.ReadFailed).data_len;
    }
}

pub const WriteError = error{
    /// One operation sent nothing within its time: a client that does not
    /// read.
    Timeout,
    /// A broken connection: the client has gone, or an error of the system.
    WriteFailed,
} || std.Io.Cancelable;

/// The most slices `writeAll` takes after its header.
pub const max_parts = 4;

/// Writes `header`, then each of `parts`, in as few operations as the
/// system takes; each operation must send something within `limit`.
pub fn writeAll(io: std.Io, stream: net.Stream, header: []const u8, parts: []const []const u8, limit: std.Io.Duration) WriteError!void {
    var head = header;
    var storage: [max_parts][]const u8 = undefined;
    @memcpy(storage[0..parts.len], parts);
    var rest: [][]const u8 = storage[0..parts.len];
    const timeout: std.Io.Timeout = .{ .duration = .{ .raw = limit, .clock = .awake } };
    while (true) {
        while (rest.len > 0 and rest[0].len == 0) rest = rest[1..];
        if (head.len == 0 and rest.len == 0) return;
        const result = io.operateTimeout(.{ .net_write = .{
            .socket_handle = stream.socket.handle,
            .header = head,
            .data = rest,
        } }, timeout) catch |err| switch (err) {
            error.Timeout, error.Canceled => |e| return e,
            error.ConcurrencyUnavailable => return error.WriteFailed,
        };
        var sent = result.net_write catch return error.WriteFailed;
        if (sent == 0) return error.WriteFailed;
        const from_head = @min(sent, head.len);
        head = head[from_head..];
        sent -= from_head;
        while (sent > 0) {
            const from_part = @min(sent, rest[0].len);
            rest[0] = rest[0][from_part..];
            sent -= from_part;
            if (rest[0].len == 0) rest = rest[1..];
        }
    }
}
