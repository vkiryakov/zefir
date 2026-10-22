//! Writes commands in RESP3. A command is an array of bulk strings, the
//! only form a server takes from a client: `GET session:42` is
//! `*2\r\n$3\r\nGET\r\n$10\r\nsession:42\r\n`. An argument is bytes, any
//! byte included: `\r\n` and `\x00` inside it go out as they are.
//!
//! The bytes go into the buffer of the `std.Io.Writer` it wraps, the
//! writer of the connection, and nothing leaves before its `flush`: one
//! exchange, a pipeline included, is one write, cut only where the buffer
//! fills up. An argument that does not fit what is left of the buffer goes
//! to the sink with its header in one `writeVecAll`, without a copy: a
//! large value leaves the caller's memory for the socket as it is.
//!
//! - `command(args)` writes a whole command of strings.
//! - `arrayHeader(n)` starts a command of `n` arguments, and `bulk(bytes)`
//!   writes one of them; the caller writes exactly `n`. Numbers, enums and
//!   other values are turned into their text first and written with
//!   `bulk`.
//!
//! The arguments are borrowed only while a call runs: once `bulk` returns,
//! the writer holds no reference to them.

const std = @import("std");

const Writer = @This();

/// The buffered writer of the connection.
out: *std.Io.Writer,

pub const Error = std.Io.Writer.Error;

/// The longest header of a bulk string: `$`, the 20 digits of the largest
/// length and CRLF.
const max_header = 1 + 20 + 2;

comptime {
    std.debug.assert(@bitSizeOf(usize) <= 64);
}

pub fn init(out: *std.Io.Writer) Writer {
    return .{ .out = out };
}

/// Writes `args` as one command: the array header, then each argument as a
/// bulk string.
pub fn command(w: Writer, args: []const []const u8) Error!void {
    try w.arrayHeader(args.len);
    for (args) |arg| try w.bulk(arg);
}

/// Writes `*<n>\r\n`, the header of a command of `n` arguments.
pub fn arrayHeader(w: Writer, n: usize) Error!void {
    try w.out.print("*{d}\r\n", .{n});
}

/// Writes one argument as a bulk string: `$<length>\r\n`, the bytes and
/// CRLF. When they fit what is left of the buffer, they are copied there;
/// otherwise the header, `bytes` and CRLF go to the sink in one
/// `writeVecAll`, and `bytes` is not copied.
pub fn bulk(w: Writer, bytes: []const u8) Error!void {
    var header_buffer: [max_header]u8 = undefined;
    header_buffer[0] = '$';
    const digits = std.fmt.printInt(header_buffer[1..], bytes.len, 10, .lower, .{});
    header_buffer[1 + digits ..][0..2].* = "\r\n".*;
    const header = header_buffer[0 .. 1 + digits + 2];

    if (header.len + bytes.len + 2 <= w.out.unusedCapacityLen()) {
        try w.out.writeAll(header);
        try w.out.writeAll(bytes);
        try w.out.writeAll("\r\n");
        return;
    }
    var data = [_][]const u8{ header, bytes, "\r\n" };
    try w.out.writeVecAll(&data);
}
