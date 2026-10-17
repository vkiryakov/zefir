//! The request of a context (design section 6), as `ctx.request`: its
//! method and path, its headers and cookies as they came, what `Accept`
//! takes, the client's address and the body as a stream. Strings it
//! returns live in the request's arena.
const std = @import("std");
const Exchange = @import("Backend.zig").Exchange;

const Request = @This();

method: std.http.Method,
/// The path as it came, percent-encoded, without the query string:
/// "/api/v1/todos/42". `*` for `OPTIONS *`.
path: []const u8,
/// Internal to the server.
internal: Internal,

pub const Internal = struct {
    exchange: *Exchange,
    io: std.Io,
    /// What follows '?' in the target, without it.
    query: []const u8 = "",
    body: ?BodyReader = null,
};

/// The value of the first header field `name`, which is case-insensitive.
pub fn header(r: *const Request, name: []const u8) ?[]const u8 {
    for (r.internal.exchange.fields) |f| {
        if (std.ascii.eqlIgnoreCase(f.name, name)) return f.value;
    }
    return null;
}

/// The value of the first cookie `name` (case matters) in the `Cookie`
/// fields, without the quotes around it.
pub fn cookie(r: *const Request, name: []const u8) ?[]const u8 {
    for (r.internal.exchange.fields) |f| {
        if (!std.ascii.eqlIgnoreCase(f.name, "cookie")) continue;
        var pairs = std.mem.splitScalar(u8, f.value, ';');
        while (pairs.next()) |pair| {
            const item = std.mem.trim(u8, pair, " \t");
            const eq = std.mem.findScalar(u8, item, '=') orelse continue;
            if (!std.mem.eql(u8, std.mem.trim(u8, item[0..eq], " \t"), name)) continue;
            const value = std.mem.trim(u8, item[eq + 1 ..], " \t");
            if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') return value[1 .. value.len - 1];
            return value;
        }
    }
    return null;
}

/// Whether the client takes a response of type `mime`, such as
/// "text/html": true without `Accept`; else the most specific range of
/// `Accept` that covers `mime` (`text/html`, then `text/*`, then `*/*`)
/// must have a q above 0.
pub fn accepts(r: *const Request, mime: []const u8) bool {
    const wanted = std.mem.trim(u8, mime[0 .. std.mem.findScalar(u8, mime, ';') orelse mime.len], " \t");
    const slash = std.mem.findScalar(u8, wanted, '/') orelse return false;
    var any_accept = false;
    // The best match so far: 0 for */*, 1 for type/*, 2 for type/subtype.
    var best: ?u2 = null;
    var best_q_positive = false;
    for (r.internal.exchange.fields) |f| {
        if (!std.ascii.eqlIgnoreCase(f.name, "accept")) continue;
        any_accept = true;
        var ranges = std.mem.splitScalar(u8, f.value, ',');
        while (ranges.next()) |item| {
            var parts = std.mem.splitScalar(u8, item, ';');
            const range = std.mem.trim(u8, parts.first(), " \t");
            const specificity = matchRange(range, wanted, slash) orelse continue;
            if (best) |b| if (specificity <= b) continue;
            best = specificity;
            best_q_positive = qPositive(&parts);
        }
    }
    if (!any_accept) return true;
    return best != null and best_q_positive;
}

/// How specifically `range` covers `wanted` (`type/subtype`, the '/' at
/// `slash`): 2 for the same type, 1 for `type/*`, 0 for `*/*`; null when it
/// does not.
fn matchRange(range: []const u8, wanted: []const u8, slash: usize) ?u2 {
    if (std.mem.eql(u8, range, "*/*")) return 0;
    const range_slash = std.mem.findScalar(u8, range, '/') orelse return null;
    if (!std.ascii.eqlIgnoreCase(range[0..range_slash], wanted[0..slash])) return null;
    const sub = range[range_slash + 1 ..];
    if (std.mem.eql(u8, sub, "*")) return 1;
    return if (std.ascii.eqlIgnoreCase(sub, wanted[slash + 1 ..])) 2 else null;
}

/// Whether the `q` among the parameters is above 0; 1 without one.
fn qPositive(params: *std.mem.SplitIterator(u8, .scalar)) bool {
    while (params.next()) |param| {
        const p = std.mem.trim(u8, param, " \t");
        if (p.len < 2 or (p[0] != 'q' and p[0] != 'Q') or p[1] != '=') continue;
        const value = p[2..];
        // q = ( "0" [ "." 0*3DIGIT ] ) / ( "1" [ "." 0*3("0") ] ): above 0
        // unless every digit is 0.
        for (value) |c| {
            if (c >= '1' and c <= '9') return true;
        }
        return false;
    }
    return true;
}

/// The address of the client; null when the backend has none.
pub fn clientAddress(r: *const Request) ?std.Io.net.IpAddress {
    return r.internal.exchange.client;
}

/// The body as a stream, read as the handler takes it; the same reader on
/// each call. A broken connection, or the request canceled while it reads,
/// is `error.ReadFailed` of `std.Io.Reader`.
pub fn bodyReader(r: *Request) error{BodyConsumed}!*std.Io.Reader {
    if (r.internal.body == null) {
        r.internal.body = .{ .exchange = r.internal.exchange, .io = r.internal.io };
        const body = &r.internal.body.?;
        body.interface.buffer = &body.buffer;
    }
    return &r.internal.body.?.interface;
}

/// `bodyReader`'s reader over `Exchange.readBody`. It stays where
/// `bodyReader` made it: its interface points into it.
pub const BodyReader = struct {
    exchange: *Exchange,
    io: std.Io,
    interface: std.Io.Reader = .{
        .vtable = &.{ .stream = stream },
        .buffer = &.{},
        .seek = 0,
        .end = 0,
    },
    /// What the backend returned when the reader gave `ReadFailed`.
    err: ?Exchange.ReadError = null,
    ended: bool = false,
    buffer: [1024]u8 = undefined,

    fn stream(io_reader: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const b: *BodyReader = @fieldParentPtr("interface", io_reader);
        if (b.ended) return error.EndOfStream;
        const dest = limit.slice(try w.writableSliceGreedy(1));
        const n = b.exchange.readBody(b.io, dest) catch |err| {
            b.err = err;
            return error.ReadFailed;
        };
        if (n == 0) {
            b.ended = true;
            return error.EndOfStream;
        }
        w.advance(n);
        return n;
    }
};

const testing = std.testing;
const h1 = @import("h1/head.zig");

/// A request over `fields` and `body`, without a backend.
const Fake = struct {
    exchange: Exchange,
    body: []const u8,
    read: usize = 0,

    fn init(fields: []const h1.Field, body: []const u8) Fake {
        return .{ .exchange = .{
            .ptr = undefined,
            .vtable = &.{
                .bodyLength = undefined,
                .readBody = readBody,
                .bodyFailure = undefined,
                .watch = undefined,
                .writeHead = undefined,
                .writeBody = undefined,
                .flush = undefined,
                .finish = undefined,
                .abort = undefined,
            },
            .method = .GET,
            .target = "/",
            .version = .http11,
            .fields = fields,
            .client = null,
            .arena = undefined,
        }, .body = body };
    }

    fn request(f: *Fake) Request {
        f.exchange.ptr = f;
        return .{ .method = .GET, .path = "/", .internal = .{ .exchange = &f.exchange, .io = testing.io } };
    }

    /// Three bytes at most per read, so the reader reads more than once.
    fn readBody(ptr: *anyopaque, _: std.Io, buffer: []u8) Exchange.ReadError!usize {
        const f: *Fake = @ptrCast(@alignCast(ptr));
        const n = @min(buffer.len, 3, f.body.len - f.read);
        @memcpy(buffer[0..n], f.body[f.read..][0..n]);
        f.read += n;
        return n;
    }
};

test "accepts: ranges and q values" {
    const Case = struct { accept: ?[]const u8, mime: []const u8, ok: bool };
    for ([_]Case{
        .{ .accept = null, .mime = "text/html", .ok = true },
        .{ .accept = "text/html", .mime = "text/html", .ok = true },
        .{ .accept = "TEXT/HTML", .mime = "text/html; charset=utf-8", .ok = true },
        .{ .accept = "application/json", .mime = "text/html", .ok = false },
        .{ .accept = "text/*", .mime = "text/html", .ok = true },
        .{ .accept = "*/*", .mime = "image/png", .ok = true },
        .{ .accept = "text/html;q=0", .mime = "text/html", .ok = false },
        .{ .accept = "text/html; q=0.000", .mime = "text/html", .ok = false },
        .{ .accept = "text/html;level=1;q=0.5", .mime = "text/html", .ok = true },
        .{ .accept = "text/html;q=0.001", .mime = "text/html", .ok = true },
        // The most specific range decides, wherever it stands.
        .{ .accept = "text/*, text/html;q=0", .mime = "text/html", .ok = false },
        .{ .accept = "text/html;q=0, */*", .mime = "text/html", .ok = false },
        .{ .accept = "*/*;q=0, text/*;q=0.2", .mime = "text/plain", .ok = true },
        .{ .accept = "*/*;q=0, text/*;q=0.2", .mime = "image/png", .ok = false },
        .{ .accept = "application/json, text/html;q=0.9", .mime = "text/html", .ok = true },
        .{ .accept = "", .mime = "text/html", .ok = false },
        .{ .accept = "text/html", .mime = "html", .ok = false },
    }) |c| {
        var fields: [1]h1.Field = .{.{ .name = "Accept", .value = c.accept orelse "" }};
        var fake: Fake = .init(if (c.accept != null) &fields else &.{}, "");
        const r = fake.request();
        testing.expectEqual(c.ok, r.accepts(c.mime)) catch |err| {
            std.debug.print("Accept: {?s}, mime {s}\n", .{ c.accept, c.mime });
            return err;
        };
    }
    // Two Accept fields are one list.
    var two: Fake = .init(&.{ .{ .name = "accept", .value = "text/plain" }, .{ .name = "accept", .value = "text/html;q=0" } }, "");
    const r = two.request();
    try testing.expect(r.accepts("text/plain"));
    try testing.expect(!r.accepts("text/html"));
}

test "header and cookie: the first of a name; cookies by their exact name" {
    var fake: Fake = .init(&.{
        .{ .name = "X-Token", .value = "first" },
        .{ .name = "x-token", .value = "second" },
        .{ .name = "Cookie", .value = "theme=dark; session=\"abc 1\";flag" },
        .{ .name = "cookie", .value = "session=other; Lang=en" },
    }, "");
    const r = fake.request();
    try testing.expectEqualStrings("first", r.header("x-token").?);
    try testing.expectEqual(null, r.header("x-missing"));
    try testing.expectEqualStrings("dark", r.cookie("theme").?);
    try testing.expectEqualStrings("abc 1", r.cookie("session").?);
    try testing.expectEqualStrings("en", r.cookie("Lang").?);
    try testing.expectEqual(null, r.cookie("lang"));
    try testing.expectEqual(null, r.cookie("flag"));
    try testing.expectEqual(null, r.clientAddress());
}

test "bodyReader reads the whole body" {
    const body = "{\"title\":\"Buy milk\",\"done\":false}";
    var fake: Fake = .init(&.{}, body);
    var r = fake.request();
    const reader = try r.bodyReader();
    try testing.expect(reader == try r.bodyReader());
    const all = try reader.allocRemaining(testing.allocator, .unlimited);
    defer testing.allocator.free(all);
    try testing.expectEqualStrings(body, all);
    try testing.expectError(error.EndOfStream, reader.takeByte());
}
