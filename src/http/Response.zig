//! The response of a context (design section 8), as `ctx.response`: its
//! status, its header fields and a body held until the handler returns.
//! Nothing goes to the client before that, so an error can still replace
//! the response.
//!
//! ```zig
//! try ctx.response.setHeader("cache-control", "no-store");
//! try ctx.response.status(404).html(not_found_page);
//! ```
const std = @import("std");
const h1 = @import("h1/head.zig");

const Response = @This();

/// Internal to the server.
internal: Internal,

pub const Internal = struct {
    arena: std.mem.Allocator,
    /// The status `status` set.
    code: ?u16 = null,
    /// The header fields, copied into the arena; `Content-Type` is kept
    /// in `content_type`.
    headers: std.ArrayList(h1.Field) = .empty,
    content_type: ?[]const u8 = null,
    body: ?[]const u8 = null,

    /// Whether the handler wrote a response: a status or a body. A `!void`
    /// handler that wrote none answers 204.
    pub fn written(i: *const Internal) bool {
        return i.code != null or i.body != null;
    }
};

/// `InvalidHeaderValue`: a name that is not a token (RFC 9110), or a value
/// with CR, LF, NUL or another control character but HTAB.
/// `ReservedHeader`: a field the backend writes itself, from the body and
/// the connection: `Content-Length`, `Transfer-Encoding`, `Connection`,
/// `Keep-Alive`, `TE`, `Trailer`, `Upgrade` and `Date`.
pub const HeaderError = error{ InvalidHeaderValue, ReservedHeader, OutOfMemory };

/// The fields of framing, of the connection and `Date`: the backend writes
/// them, so that what the head says always matches the body it sends.
const reserved_names = [_][]const u8{ "content-length", "transfer-encoding", "connection", "keep-alive", "te", "trailer", "upgrade", "date" };

/// Sets the status; chainable: `try ctx.response.status(404).html(page)`.
/// Without it a body goes out as 200, and no body at all as 204.
pub fn status(r: *Response, code: u16) *Response {
    r.internal.code = code;
    return r;
}

/// Sets the header field `name` to `value`, in place of a field of that
/// name set before (names are case-insensitive). Both are copied.
pub fn setHeader(r: *Response, name: []const u8, value: []const u8) HeaderError!void {
    if (!validName(name) or !validValue(value)) return error.InvalidHeaderValue;
    for (reserved_names) |reserved| {
        if (std.ascii.eqlIgnoreCase(name, reserved)) return error.ReservedHeader;
    }
    const arena = r.internal.arena;
    const copy = try arena.dupe(u8, value);
    if (std.ascii.eqlIgnoreCase(name, "content-type")) {
        r.internal.content_type = copy;
        return;
    }
    for (r.internal.headers.items) |*f| {
        if (std.ascii.eqlIgnoreCase(f.name, name)) {
            f.value = copy;
            return;
        }
    }
    try r.internal.headers.append(arena, .{ .name = try arena.dupe(u8, name), .value = copy });
}

/// The body `bytes` as `text/plain; charset=utf-8`; copied.
pub fn text(r: *Response, bytes: []const u8) error{OutOfMemory}!void {
    return r.setBody("text/plain; charset=utf-8", bytes);
}

/// The body `bytes` as `text/html; charset=utf-8`; copied.
pub fn html(r: *Response, bytes: []const u8) error{OutOfMemory}!void {
    return r.setBody("text/html; charset=utf-8", bytes);
}

/// `value` as the JSON body (`application/json`), fields under their Zig
/// names. A handler that returns `http.Json(T)` answers through it.
pub fn json(r: *Response, value: anytype) error{OutOfMemory}!void {
    const bytes = try std.json.Stringify.valueAlloc(r.internal.arena, value, .{});
    r.internal.content_type = "application/json";
    r.internal.body = bytes;
}

fn setBody(r: *Response, content_type: []const u8, bytes: []const u8) error{OutOfMemory}!void {
    r.internal.body = try r.internal.arena.dupe(u8, bytes);
    r.internal.content_type = content_type;
}

fn validName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| {
        if (!h1.isToken(c)) return false;
    }
    return true;
}

fn validValue(value: []const u8) bool {
    for (value) |c| {
        if (!h1.isValueChar(c)) return false;
    }
    return true;
}

const testing = std.testing;

test "setHeader rejects CR, LF and NUL" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var r: Response = .{ .internal = .{ .arena = arena_state.allocator() } };

    for ([_][2][]const u8{
        .{ "x-a", "one\r\nset-cookie: evil=1" },
        .{ "x-a", "one\ntwo" },
        .{ "x-a", "one\rtwo" },
        .{ "x-a", "one\x00two" },
        .{ "x-a", "bell\x07" },
        .{ "x-a\r\nx-b", "1" },
        .{ "x-a\x00", "1" },
        .{ "x a", "1" },
        .{ "x-a:", "1" },
        .{ "", "1" },
    }) |h| {
        try testing.expectError(error.InvalidHeaderValue, r.setHeader(h[0], h[1]));
    }
    try testing.expectEqual(0, r.internal.headers.items.len);

    // A tab and bytes past ASCII are fine; a second set replaces the first.
    try r.setHeader("X-Note", "a\tb caf\xc3\xa9");
    try r.setHeader("x-note", "second");
    try r.setHeader("Retry-After", "5");
    try testing.expectEqual(2, r.internal.headers.items.len);
    try testing.expectEqualStrings("X-Note", r.internal.headers.items[0].name);
    try testing.expectEqualStrings("second", r.internal.headers.items[0].value);

    // The value is copied: the caller's buffer may go.
    var buffer = "text/csv".*;
    try r.setHeader("content-type", &buffer);
    buffer[0] = 'X';
    try testing.expectEqualStrings("text/csv", r.internal.content_type.?);
    try testing.expectEqual(2, r.internal.headers.items.len);
}

test "setHeader refuses the fields the backend writes itself, in any case" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var r: Response = .{ .internal = .{ .arena = arena_state.allocator() } };

    for ([_][]const u8{
        "content-length", "Content-Length", "transfer-encoding", "TRANSFER-ENCODING",
        "connection",     "Keep-Alive",     "te",                "Trailer",
        "upgrade",        "date",           "DATE",
    }) |name| {
        try testing.expectError(error.ReservedHeader, r.setHeader(name, "1"));
    }
    try testing.expectEqual(0, r.internal.headers.items.len);
    // Names that only begin or end like one are the application's.
    try r.setHeader("content-length-hint", "1");
    try r.setHeader("x-date", "1");
    try r.setHeader("tea", "1");
    try testing.expectEqual(3, r.internal.headers.items.len);
}

test "text, html and json set the body and its type; status is chainable" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var r: Response = .{ .internal = .{ .arena = arena_state.allocator() } };
    try testing.expect(!r.internal.written());

    try r.status(404).html("<h1>Not here</h1>");
    try testing.expectEqual(404, r.internal.code.?);
    try testing.expectEqualStrings("text/html; charset=utf-8", r.internal.content_type.?);
    try testing.expectEqualStrings("<h1>Not here</h1>", r.internal.body.?);
    try testing.expect(r.internal.written());

    try r.text("plain");
    try testing.expectEqualStrings("text/plain; charset=utf-8", r.internal.content_type.?);
    try r.json(.{ .id = 7, .title = "Buy milk" });
    try testing.expectEqualStrings("application/json", r.internal.content_type.?);
    try testing.expectEqualStrings("{\"id\":7,\"title\":\"Buy milk\"}", r.internal.body.?);
}
