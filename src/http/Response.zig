//! The response of a context (design section 8), as `ctx.response`: its
//! status, its header fields and a body held until the handler returns.
//! Nothing goes to the client before that, so an error can still replace
//! the response.
//!
//! ```zig
//! try ctx.response.setHeader("cache-control", "no-store");
//! try ctx.response.status(404).html(not_found_page);
//! ```
//!
//! A response goes through three states, in order: `uncommitted` (its
//! status, fields and body can change, and an error replaces it),
//! `committed` (its head has gone to the client: a change is
//! `error.ResponseCommitted`) and `finished`, once.
const std = @import("std");
const v = @import("validator");
const h1 = @import("h1/head.zig");
const Exchange = @import("Backend.zig").Exchange;
const json_out = @import("output/json_out.zig");

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
    state: State = .uncommitted,

    /// Whether the handler wrote a response: a status or a body. A `!void`
    /// handler that wrote none answers 204.
    pub fn written(i: *const Internal) bool {
        return i.code != null or i.body != null;
    }
};

/// Where a response is: `uncommitted` until its head goes to the client,
/// then `committed`, then `finished`, once, whether it ended whole or cut.
pub const State = enum { uncommitted, committed, finished };

/// `InvalidHeaderValue`: a name that is not a token (RFC 9110), or a value
/// with CR, LF, NUL or another control character but HTAB.
/// `ReservedHeader`: a field the backend writes itself, from the body and
/// the connection: `Content-Length`, `Transfer-Encoding`, `Connection`,
/// `Keep-Alive`, `TE`, `Trailer`, `Upgrade` and `Date`.
/// `ResponseCommitted`: the head of the response has gone to the client.
pub const SetError = error{ InvalidHeaderValue, ReservedHeader, ResponseCommitted, OutOfMemory };

/// The errors of `json`: those of setting the body, of the transforms of
/// `T` (`v.TransformError(T)`), and of writing it.
fn JsonError(comptime T: type) type {
    return SetError || Exchange.WriteError || v.TransformError(T);
}

/// The fields of framing, of the connection and `Date`: the backend writes
/// them, so that what the head says always matches the body it sends.
const reserved_names = [_][]const u8{ "content-length", "transfer-encoding", "connection", "keep-alive", "te", "trailer", "upgrade", "date" };

/// Sets the status; chainable: `try ctx.response.status(404).html(page)`.
/// Without it a body goes out as 200, and no body at all as 204. Once the
/// response is committed, its status has gone out and this changes nothing.
pub fn status(r: *Response, code: u16) *Response {
    if (r.internal.state == .uncommitted) r.internal.code = code;
    return r;
}

/// Where the response is: `uncommitted`, `committed` or `finished`.
pub fn state(r: *const Response) State {
    return r.internal.state;
}

/// Sets the header field `name` to `value`, in place of a field of that
/// name set before (names are case-insensitive). Both are copied.
pub fn setHeader(r: *Response, name: []const u8, value: []const u8) SetError!void {
    try r.checkField(name, value);
    return r.putField(name, try r.internal.arena.dupe(u8, value));
}

/// Sets the header field `name` to `fmt` formatted with `args`, as
/// `setHeader` does:
/// `try ctx.response.setHeaderFmt("server-timing", "app;dur={d}", .{ms});`
pub fn setHeaderFmt(r: *Response, name: []const u8, comptime fmt: []const u8, args: anytype) SetError!void {
    if (r.internal.state != .uncommitted) return error.ResponseCommitted;
    const value = try std.fmt.allocPrint(r.internal.arena, fmt, args);
    try r.checkField(name, value);
    return r.putField(name, value);
}

/// The body `bytes` as `text/plain; charset=utf-8`; copied.
pub fn text(r: *Response, bytes: []const u8) error{ ResponseCommitted, OutOfMemory }!void {
    return r.setBody("text/plain; charset=utf-8", bytes);
}

/// The body `bytes` as `text/html; charset=utf-8`; copied.
pub fn html(r: *Response, bytes: []const u8) error{ ResponseCommitted, OutOfMemory }!void {
    return r.setBody("text/html; charset=utf-8", bytes);
}

/// `value` as the JSON body (`application/json`): the transforms of its
/// `field_rules` run first, on a copy (`v.transform`), then it is written
/// with the outside names of its fields (`v.rename`), the Zig names where
/// it has none. A handler that returns `http.Json(T)` answers through it.
/// An error of a transform of its own comes back as it is, for the error
/// handler.
///
/// ```zig
/// try ctx.response.status(201).json(dto.TodoResponse.from(todo));
/// ```
pub fn json(r: *Response, value: anytype) JsonError(@TypeOf(value))!void {
    if (r.internal.state != .uncommitted) return error.ResponseCommitted;
    r.internal.body = try json_out.encode(r.internal.arena, value, .{});
    r.internal.content_type = "application/json";
}

fn setBody(r: *Response, content_type: []const u8, bytes: []const u8) error{ ResponseCommitted, OutOfMemory }!void {
    if (r.internal.state != .uncommitted) return error.ResponseCommitted;
    r.internal.body = try r.internal.arena.dupe(u8, bytes);
    r.internal.content_type = content_type;
}

/// Whether `name` and `value` may be set now.
fn checkField(r: *const Response, name: []const u8, value: []const u8) SetError!void {
    if (r.internal.state != .uncommitted) return error.ResponseCommitted;
    if (!validName(name) or !validValue(value)) return error.InvalidHeaderValue;
    for (reserved_names) |reserved| {
        if (std.ascii.eqlIgnoreCase(name, reserved)) return error.ReservedHeader;
    }
}

/// Sets the field `name` to `value`, which lives in the arena already.
fn putField(r: *Response, name: []const u8, value: []const u8) error{OutOfMemory}!void {
    const arena = r.internal.arena;
    if (std.ascii.eqlIgnoreCase(name, "content-type")) {
        r.internal.content_type = value;
        return;
    }
    for (r.internal.headers.items) |*f| {
        if (std.ascii.eqlIgnoreCase(f.name, name)) {
            f.value = value;
            return;
        }
    }
    try r.internal.headers.append(arena, .{ .name = try arena.dupe(u8, name), .value = value });
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

test "setHeader after commit is ResponseCommitted; finish happens once" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var r: Response = .{ .internal = .{ .arena = arena_state.allocator() } };
    try testing.expectEqual(.uncommitted, r.state());
    try r.status(201).setHeader("x-a", "1");

    // The server commits the response when its head goes out: from then
    // on nothing of it changes.
    r.internal.state = .committed;
    try testing.expectEqual(.committed, r.state());
    try testing.expectError(error.ResponseCommitted, r.setHeader("x-a", "2"));
    try testing.expectError(error.ResponseCommitted, r.setHeader("x-b", "2"));
    try testing.expectError(error.ResponseCommitted, r.setHeaderFmt("x-b", "{d}", .{2}));
    try testing.expectError(error.ResponseCommitted, r.text("late"));
    try testing.expectError(error.ResponseCommitted, r.html("late"));
    try testing.expectError(error.ResponseCommitted, r.json(.{ .late = true }));
    try testing.expectError(error.ResponseCommitted, r.status(500).text("late"));
    try testing.expectEqual(201, r.internal.code.?);
    try testing.expectEqual(1, r.internal.headers.items.len);
    try testing.expectEqualStrings("1", r.internal.headers.items[0].value);
    try testing.expectEqual(null, r.internal.body);
    // The server's own path, through http.testing, is in flow.zig: a
    // response is written once, and an error after commit cuts it.
}

test "setHeaderFmt formats the value" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var r: Response = .{ .internal = .{ .arena = arena_state.allocator() } };
    try r.setHeaderFmt("Server-Timing", "app;dur={d}", .{12});
    try r.setHeaderFmt("server-timing", "app;dur={d}, db;dur={d}", .{ 12, 3 });
    try testing.expectEqual(1, r.internal.headers.items.len);
    try testing.expectEqualStrings("Server-Timing", r.internal.headers.items[0].name);
    try testing.expectEqualStrings("app;dur=12, db;dur=3", r.internal.headers.items[0].value);
    try r.setHeaderFmt("content-type", "text/{s}; charset=utf-8", .{"csv"});
    try testing.expectEqualStrings("text/csv; charset=utf-8", r.internal.content_type.?);
    // What it formats is checked as setHeader checks a value.
    try testing.expectError(error.InvalidHeaderValue, r.setHeaderFmt("x-name", "{s}", .{"a\r\nset-cookie: evil=1"}));
    try testing.expectError(error.ReservedHeader, r.setHeaderFmt("content-length", "{d}", .{5}));
    try testing.expectEqual(1, r.internal.headers.items.len);
}
