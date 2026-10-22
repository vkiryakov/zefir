//! Reads commands as a Redis server does, for `FakeServer` and its `Peer`:
//! a command is an array of bulk strings, the name first, and its
//! arguments are bytes, `\r\n` and `\x00` included. The client's own
//! reader, `resp.Reader`, reads it, with the same checks.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const resp = @import("../resp.zig");

/// The most bytes a command may take: the limit of a bulk string in Redis,
/// `proto-max-bulk-len`.
pub const max_bytes = 512 * 1024 * 1024;

pub const Error = resp.Reader.Error || Allocator.Error;

/// Reads the next command from `in`, its arguments copied into `arena`;
/// null when the stream ends before it starts. Anything but a non-empty
/// array of bulk strings is a ProtocolViolation, an inline command among
/// them; a stream that ends inside the command is EndOfStream.
pub fn read(in: *Io.Reader, arena: Allocator) Error!?[]const []const u8 {
    _ = in.peekByte() catch |err| switch (err) {
        error.EndOfStream => return null,
        error.ReadFailed => return error.ReadFailed,
    };
    var reader: resp.Reader = .init(in, max_bytes);
    const n = switch (try reader.next()) {
        .array => |n| n,
        else => return error.ProtocolViolation,
    };
    if (n == 0) return error.ProtocolViolation;
    const args = try arena.alloc([]const u8, n);
    for (args) |*arg| {
        switch (try reader.next()) {
            .bulk_string => {},
            else => return error.ProtocolViolation,
        }
        arg.* = try reader.payloadAlloc(arena);
    }
    return args;
}

/// Writes `bytes` for a line of text: as they are, but a byte outside
/// printable ASCII as `?`, and at most 64 of them, then `...`. A name that
/// a command carries goes into an error this way.
pub fn writePrintable(w: *Io.Writer, bytes: []const u8) Io.Writer.Error!void {
    const shown = bytes[0..@min(bytes.len, 64)];
    for (shown) |c| try w.writeByte(if (std.ascii.isPrint(c)) c else '?');
    if (shown.len < bytes.len) try w.writeAll("...");
}
