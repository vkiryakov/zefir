//! The head of an HTTP/1.1 response and the chunked framing of its body
//! (RFC 9112 §4, §6, §7.1). Pure: bytes out, no I/O; the connection sends
//! them.
//!
//! The status line always says HTTP/1.1, also to an HTTP/1.0 client, as
//! RFC 9110 §6.2 asks; what such a client may not get is a chunked body
//! (`Framing.until_close` instead) or a connection kept open without its
//! own `Connection: keep-alive`.

const std = @import("std");
const head = @import("head.zig");
const date = @import("date.zig");

const Version = head.Version;
const Field = head.Field;

/// How the body of a response is delimited on the wire.
pub const Framing = union(enum) {
    /// No body and no field for one: 1xx, 204, 304.
    none,
    /// `Content-Length`; a HEAD response gives the length and no body.
    length: u64,
    /// `Transfer-Encoding: chunked`, for HTTP/1.1.
    chunked,
    /// The end of the connection ends the body: a stream to an HTTP/1.0
    /// client. The head says `Connection: close`.
    until_close,
};

/// Writes the head: the status line, `fields` in order, `Date`, the field
/// of `framing`, `Connection: close` when `close` (or the body ends with
/// the connection), `Connection: keep-alive` to an HTTP/1.0 request that
/// keeps it, and the empty line. The fields are written as given: the
/// caller leaves out those of framing, `Connection` and `Date`.
pub fn writeHead(
    w: *std.Io.Writer,
    version: Version,
    status: u16,
    fields: []const Field,
    framing: Framing,
    close: bool,
    imf_date: *const [date.len]u8,
) std.Io.Writer.Error!void {
    try w.print("HTTP/1.1 {d} {s}\r\n", .{ status, reason(status) });
    for (fields) |field| try w.print("{s}: {s}\r\n", .{ field.name, field.value });
    try w.print("Date: {s}\r\n", .{imf_date});
    switch (framing) {
        .none, .until_close => {},
        .length => |n| try w.print("Content-Length: {d}\r\n", .{n}),
        .chunked => try w.writeAll("Transfer-Encoding: chunked\r\n"),
    }
    if (close or framing == .until_close) {
        try w.writeAll("Connection: close\r\n");
    } else if (version == .http10) {
        try w.writeAll("Connection: keep-alive\r\n");
    }
    try w.writeAll("\r\n");
}

/// The reason phrase of `status`; empty for a status std has no name for.
pub fn reason(status: u16) []const u8 {
    if (status > std.math.maxInt(u10)) return "";
    const known: std.http.Status = @fromBackingInt(@intCast(status));
    return known.phrase() orelse "";
}

/// The longest chunk-size line: 16 hex digits and CRLF.
pub const max_chunk_header = 18;

/// The line before a chunk of `size` bytes, its size in hex and CRLF; the
/// chunk's data follows it, then `chunk_end`. `size` must not be 0: a chunk
/// of 0 is `last_chunk`, the end of the body.
pub fn chunkHeader(out: *[max_chunk_header]u8, size: u64) []const u8 {
    std.debug.assert(size > 0);
    return std.fmt.bufPrint(out, "{x}\r\n", .{size}) catch unreachable; // 16 digits at most
}

/// After the data of each chunk.
pub const chunk_end = "\r\n";

/// The end of a chunked body: the last chunk and no trailer fields.
pub const last_chunk = "0\r\n\r\n";

const testing = std.testing;

const test_date = "Sun, 06 Nov 1994 08:49:37 GMT";

fn expectHead(expected: []const u8, version: Version, status: u16, fields: []const Field, framing: Framing, close: bool) !void {
    var buffer: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try writeHead(&w, version, status, fields, framing, close, test_date);
    try testing.expectEqualStrings(expected, w.buffered());
}

test "writeHead: the status line, the fields, Date and Content-Length" {
    try expectHead("HTTP/1.1 200 OK\r\n" ++
        "content-type: text/plain; charset=utf-8\r\n" ++
        "x-request-id: 7\r\n" ++
        "Date: Sun, 06 Nov 1994 08:49:37 GMT\r\n" ++
        "Content-Length: 5\r\n" ++
        "\r\n", .http11, 200, &.{
        .{ .name = "content-type", .value = "text/plain; charset=utf-8" },
        .{ .name = "x-request-id", .value = "7" },
    }, .{ .length = 5 }, false);
    // A status std does not name keeps the space before the empty reason.
    try expectHead("HTTP/1.1 599 \r\nDate: " ++ test_date ++ "\r\nContent-Length: 0\r\n\r\n", .http11, 599, &.{}, .{ .length = 0 }, false);
}

test "writeHead: 204 and 304 have no field of framing; chunked; close" {
    try expectHead("HTTP/1.1 204 No Content\r\nDate: " ++ test_date ++ "\r\n\r\n", .http11, 204, &.{}, .none, false);
    try expectHead("HTTP/1.1 304 Not Modified\r\netag: \"a\"\r\nDate: " ++ test_date ++ "\r\n\r\n", .http11, 304, &.{.{ .name = "etag", .value = "\"a\"" }}, .none, false);
    try expectHead("HTTP/1.1 200 OK\r\nDate: " ++ test_date ++ "\r\nTransfer-Encoding: chunked\r\n\r\n", .http11, 200, &.{}, .chunked, false);
    try expectHead("HTTP/1.1 400 Bad Request\r\nDate: " ++ test_date ++ "\r\nContent-Length: 11\r\nConnection: close\r\n\r\n", .http11, 400, &.{}, .{ .length = 11 }, true);
}

test "writeHead: HTTP/1.0 keeps alive only with its own keep-alive; a stream to it ends with the connection" {
    try expectHead("HTTP/1.1 200 OK\r\nDate: " ++ test_date ++ "\r\nContent-Length: 2\r\nConnection: keep-alive\r\n\r\n", .http10, 200, &.{}, .{ .length = 2 }, false);
    try expectHead("HTTP/1.1 200 OK\r\nDate: " ++ test_date ++ "\r\nContent-Length: 2\r\nConnection: close\r\n\r\n", .http10, 200, &.{}, .{ .length = 2 }, true);
    // Neither a length nor chunked: the close ends the body.
    try expectHead("HTTP/1.1 200 OK\r\nDate: " ++ test_date ++ "\r\nConnection: close\r\n\r\n", .http10, 200, &.{}, .until_close, false);
}

test "chunkHeader: the size in hex; the last chunk ends the body" {
    var out: [max_chunk_header]u8 = undefined;
    try testing.expectEqualStrings("1\r\n", chunkHeader(&out, 1));
    try testing.expectEqualStrings("400\r\n", chunkHeader(&out, 1024));
    try testing.expectEqualStrings("ffffffffffffffff\r\n", chunkHeader(&out, std.math.maxInt(u64)));
    try testing.expectEqualStrings("0\r\n\r\n", last_chunk);
    try testing.expectEqualStrings("", reason(1024));
    try testing.expectEqualStrings("Request Header Fields Too Large", reason(431));
}
