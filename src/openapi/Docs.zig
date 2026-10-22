//! The controller of documentation: `zefir.openapi.Docs(.{})` serves the
//! document of a server and a page that shows it. The application keeps
//! one as a field, puts it in `.controllers` and gives it the document,
//! which it writes once:
//!
//! ```zig
//! docs: zefir.openapi.Docs(.{}) = undefined, // GET /api/openapi.json and the page GET /api/docs
//!
//! const options = .{ .backend = backend, .prefix = "/api", .controllers = .{ &s.todos, &s.docs } };
//! s.docs = try .init(gpa, comptime zefir.openapi.document(@TypeOf(options), .{
//!     .info = .{ .title = "Todos API", .version = "1.0.0" },
//! }));
//! errdefer s.docs.deinit(gpa);
//! s.server = try .init(gpa, options);
//! ```
//!
//! - `GET /openapi.json`: the document as `application/json`, the same
//!   bytes as `openapi.json` in the repository, with their ETag and
//!   `Cache-Control: no-cache`: a client asks each time, and while the
//!   document has not changed it gets 304 without a body.
//! - `GET /docs`: the page of Scalar, a reference of the API in the
//!   browser, which reads the document from the route above, by its path
//!   from the server's root: the page finds it at each path the router
//!   gives the page, `/docs/` with its '/' too. The browser
//!   loads Scalar from jsDelivr, a release pinned here and checked by its
//!   hash (Subresource Integrity), so a `Content-Security-Policy` of the
//!   application must allow scripts of https://cdn.jsdelivr.net, the
//!   `<style>` elements Scalar adds (`style-src 'unsafe-inline'`) and its
//!   fonts (`font-src https://fonts.scalar.com`). The requests of "Try it"
//!   go from the browser straight to the API, never through a proxy, so
//!   the `connect-src` of a strict policy must allow the API's origin.
//!   The page has no AI panel, which would send the document and a
//!   developer's questions to Scalar's servers.
//!   `.page = null` leaves the page out.
//!
//! The paths are those of the routes within the server's prefix. When the
//! prefix comes from the config, at run time, the document has no
//! `servers`: `Docs` puts the prefix of its own route there as it serves
//! the document. A document never holds the routes of `Docs`, and in Debug
//! the server does not check them against one.
const std = @import("std");
const http = @import("http");
const tree = @import("json.zig");
const Document = @import("document.zig").Document;

/// The paths of the routes of `Docs`, within the server's prefix.
pub const DocsOptions = struct {
    /// The document.
    json: []const u8 = "/openapi.json",
    /// The page that shows it; null for none.
    page: ?[]const u8 = "/docs",
};

/// Scalar, the reference of the page: a file of a release of its npm
/// package on jsDelivr, which never changes, and the hash the browser
/// checks it by.
const scalar = struct {
    const version = "1.75.1";
    const url = "https://cdn.jsdelivr.net/npm/@scalar/api-reference@" ++ version ++ "/dist/browser/standalone.js";
    const integrity = "sha384-G+2Q2i9l3PPfmYkk0b4BAIUrs7xb/DNaTL1wCYYab4c9dIKlCyiqzC0Qx3eq9Wf6";
    /// The configuration of the reference, as JSON, which it reads from the
    /// attribute `data-configuration`: an empty `proxyUrl` sends each
    /// request of "Try it" from the browser straight to the API. Without
    /// it, a default of Scalar's decides whether a request to an absolute
    /// URL goes through its proxy, https://proxy.scalar.com. A disabled
    /// `agent` leaves out the AI panel, which Scalar shows on a local page,
    /// such as one of localhost, and which sends the document and the
    /// questions of a developer to Scalar's servers.
    const configuration = "{\"proxyUrl\":\"\",\"agent\":{\"disabled\":true}}";
};

/// The controller of documentation for the paths of `opts`.
pub fn Docs(comptime opts: DocsOptions) type {
    expectPath(opts.json, "json", "/openapi.json");
    if (opts.page) |path| expectPath(path, "page", "/docs");
    return struct {
        const Self = @This();

        /// The document it serves, as `zefir.openapi.document` built it.
        document: Document,
        /// Internal to `Docs`.
        internal: Internal,

        pub const Internal = struct {
            /// The bytes of the document, written by `init`.
            bytes: []const u8,
            etag: ETag,
            /// Where `servers` goes in `bytes`, right after `info`, when
            /// the prefix comes at run time; null when it does not.
            servers_at: ?usize,
            /// The page but the path of the document in it, which a
            /// request gets at `page_url_at`; null without a page.
            page: ?[]const u8,
            page_url_at: usize,
        };

        /// Marks a controller of documentation: a document leaves it out.
        pub const zefir_openapi_docs = {};

        pub const http_routes = http.routes(.{ .methods = if (opts.page) |path|
            .{ .json = http.get(opts.json, .{}), .page = http.get(path, .{}) }
        else
            .{ .json = http.get(opts.json, .{}) } });

        /// Writes the document, once, and the page; `deinit` frees them.
        pub fn init(gpa: std.mem.Allocator, document: Document) error{OutOfMemory}!Self {
            var out: std.Io.Writer.Allocating = .init(gpa);
            defer out.deinit();
            document.write(&out.writer) catch return error.OutOfMemory;
            const bytes = try out.toOwnedSlice();
            errdefer gpa.free(bytes);
            const page_of: ?Page = if (opts.page == null) null else try pageOf(gpa, titleOf(document));
            return .{ .document = document, .internal = .{
                .bytes = bytes,
                .etag = etagOf(bytes),
                .servers_at = if (document.runtime_prefix) serversAt(document) else null,
                .page = if (page_of) |p| p.bytes else null,
                .page_url_at = if (page_of) |p| p.url_at else 0,
            } };
        }

        pub fn deinit(d: *Self, gpa: std.mem.Allocator) void {
            gpa.free(d.internal.bytes);
            if (d.internal.page) |bytes| gpa.free(bytes);
            d.* = undefined;
        }

        /// `GET` of the document; HEAD too, as the server answers it.
        pub fn json(d: *Self, ctx: *http.Context) !void {
            const doc = try d.served(ctx);
            try ctx.response.setHeader("etag", &doc.etag);
            try ctx.response.setHeader("cache-control", "no-cache");
            const conditional = try ctx.headers(Conditional);
            if (notModified(conditional.if_none_match, &doc.etag)) {
                _ = ctx.response.status(304);
                return;
            }
            try ctx.response.text(doc.bytes);
            // After the body, which sets its own type.
            try ctx.response.setHeader("content-type", "application/json");
        }

        /// `GET` of the page, which names the document by its path from
        /// the server's root: the server's prefix and `.json`.
        pub fn page(d: *Self, ctx: *http.Context) !void {
            const i = &d.internal;
            const bytes = i.page.?;
            // The pattern of the route is the server's prefix, then the path.
            const pattern = ctx.route().?.pattern;
            const prefix = pattern[0 .. pattern.len - opts.page.?.len];
            try ctx.response.html(try std.fmt.allocPrint(ctx.allocator(), "{s}{f}{f}{s}", .{
                bytes[0..i.page_url_at],
                Html{ .text = prefix },
                Html{ .text = opts.json },
                bytes[i.page_url_at..],
            }));
        }

        /// The bytes of the document this request gets, and their ETag:
        /// with a prefix that comes at run time, those of the document
        /// with that prefix in `servers`, written for the request.
        fn served(d: *const Self, ctx: *http.Context) error{OutOfMemory}!Served {
            const i = &d.internal;
            const at = i.servers_at orelse return .{ .bytes = i.bytes, .etag = i.etag };
            // The pattern of the route is the server's prefix, then the path.
            const pattern = ctx.route().?.pattern;
            const prefix = pattern[0 .. pattern.len - opts.json.len];
            if (prefix.len == 0) return .{ .bytes = i.bytes, .etag = i.etag };
            const arena = ctx.allocator();
            const bytes = try std.mem.concat(arena, u8, &.{ i.bytes[0..at], try serversMember(arena, prefix), i.bytes[at..] });
            return .{ .bytes = bytes, .etag = etagOf(bytes) };
        }
    };
}

/// A path of a route of `Docs` starts with '/', after the server's prefix:
/// the page names the document by both.
fn expectPath(comptime path: []const u8, comptime option: []const u8, comptime example: []const u8) void {
    if (path.len == 0 or path[0] != '/')
        @compileError("zefir.openapi: Docs: ." ++ option ++ " is \"" ++ path ++ "\", which does not start with '/'; " ++
            "write the path of the route within the server's prefix, such as ." ++ option ++ " = \"" ++ example ++ "\"");
}

/// `"` and the 16 hexadecimal digits of a hash, then `"`.
const ETag = [18]u8;

/// The ETag of the bytes of a document: their Wyhash.
fn etagOf(bytes: []const u8) ETag {
    var tag: ETag = undefined;
    _ = std.fmt.bufPrint(&tag, "\"{x:0>16}\"", .{std.hash.Wyhash.hash(0, bytes)}) catch unreachable;
    return tag;
}

/// What a request of the document gets.
const Served = struct { bytes: []const u8, etag: ETag };

/// The validators of a conditional GET: each line of `If-None-Match`.
const Conditional = struct { if_none_match: []const []const u8 = &.{} };

/// Whether `If-None-Match` names the document the client has: `*`, or a
/// tag of one of its lines whose opaque part is that of `etag`, weak or
/// not (RFC 9110, 13.1.2).
fn notModified(lines: []const []const u8, etag: []const u8) bool {
    for (lines) |line| {
        if (std.mem.eql(u8, std.mem.trim(u8, line, " \t"), "*")) return true;
        var rest = line;
        while (nextTag(&rest)) |tag| {
            if (std.mem.eql(u8, tag, etag)) return true;
        }
    }
    return false;
}

/// The opaque part of the next entity tag of a list, `"a", W/"b"`, in its
/// quotes; null at the end or at an element that is not a tag. A tag may
/// hold a comma: the list is read tag by tag, not split at commas.
fn nextTag(rest: *[]const u8) ?[]const u8 {
    var s = std.mem.trimStart(u8, rest.*, " \t,");
    if (std.mem.startsWith(u8, s, "W/")) s = s[2..];
    if (s.len < 2 or s[0] != '"') return null;
    const end = std.mem.findScalar(u8, s[1..], '"') orelse return null;
    rest.* = s[end + 2 ..];
    return s[0 .. end + 2];
}

/// Where `servers` goes in the bytes of `document`: right after `info`,
/// its second member. An object's members are written one after another,
/// so the document begins with the bytes of an object of its first two
/// members, but for that object's end. Null for a tree that does not begin
/// with `openapi` and `info`, as no document of `zefir.openapi.document`.
fn serversAt(document: Document) ?usize {
    if (document.root != .object) return null;
    const members = document.root.object;
    if (members.len < 2 or !std.mem.eql(u8, members[1].key, "info")) return null;
    var head: std.Io.Writer.Discarding = .init(&.{});
    // Writing to a Discarding writer never fails.
    tree.write(.{ .object = members[0..2] }, &head.writer) catch unreachable;
    return @intCast(head.fullCount() - "\n}\n".len);
}

/// `servers` with the URL `prefix`, as it goes in after `info`: a comma,
/// then what an object of that member alone holds within its braces.
fn serversMember(arena: std.mem.Allocator, prefix: []const u8) error{OutOfMemory}![]const u8 {
    const url = [_]tree.Member{.{ .key = "url", .value = .{ .string = prefix } }};
    const servers = [_]tree.Node{.{ .object = &url }};
    const root = [_]tree.Member{.{ .key = "servers", .value = .{ .array = &servers } }};
    var out: std.Io.Writer.Allocating = .init(arena);
    tree.write(.{ .object = &root }, &out.writer) catch return error.OutOfMemory;
    const text = out.written();
    text[0] = ',';
    return text[0 .. text.len - "\n}\n".len];
}

/// The title of the document, `info.title`, for the page.
fn titleOf(document: Document) []const u8 {
    if (document.root != .object) return "API";
    for (document.root.object) |m| {
        if (!std.mem.eql(u8, m.key, "info") or m.value != .object) continue;
        for (m.value.object) |field| {
            if (std.mem.eql(u8, field.key, "title") and field.value == .string) return field.value.string;
        }
    }
    return "API";
}

/// The page of Scalar but the path of the document in it, which goes at
/// `url_at`.
const Page = struct { bytes: []const u8, url_at: usize };

/// The page for the document titled `title`.
fn pageOf(gpa: std.mem.Allocator, title: []const u8) error{OutOfMemory}!Page {
    const head = try std.fmt.allocPrint(gpa,
        \\<!doctype html>
        \\<html>
        \\  <head>
        \\    <meta charset="utf-8">
        \\    <meta name="viewport" content="width=device-width, initial-scale=1">
        \\    <title>{f}</title>
        \\  </head>
        \\  <body>
        \\    <script id="api-reference" data-configuration="{f}" data-url="
    , .{ Html{ .text = title }, Html{ .text = scalar.configuration } });
    defer gpa.free(head);
    const tail = std.fmt.comptimePrint(
        \\"></script>
        \\    <script src="{s}" integrity="{s}" crossorigin="anonymous"></script>
        \\  </body>
        \\</html>
        \\
    , .{ scalar.url, scalar.integrity });
    return .{ .bytes = try std.mem.concat(gpa, u8, &.{ head, tail }), .url_at = head.len };
}

/// Text in HTML, as an element's content or an attribute's value.
const Html = struct {
    text: []const u8,

    pub fn format(h: Html, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (h.text) |c| switch (c) {
            '&' => try w.writeAll("&amp;"),
            '<' => try w.writeAll("&lt;"),
            '>' => try w.writeAll("&gt;"),
            '"' => try w.writeAll("&quot;"),
            else => try w.writeByte(c),
        };
    }
};

const testing = std.testing;

test "notModified: *, a tag of a list or of a line, weak or not; never a part of a tag" {
    const tag = "\"0123456789abcdef\"";
    try testing.expect(notModified(&.{tag}, tag));
    try testing.expect(notModified(&.{" * "}, tag));
    try testing.expect(notModified(&.{"W/" ++ tag}, tag));
    try testing.expect(notModified(&.{"\"x\", W/\"y\" ," ++ tag}, tag));
    try testing.expect(notModified(&.{ "\"x\"", tag }, tag));
    try testing.expect(!notModified(&.{}, tag));
    try testing.expect(!notModified(&.{"\"x\""}, tag));
    try testing.expect(!notModified(&.{"0123456789abcdef"}, tag));
    // A comma in a tag does not end it.
    try testing.expect(!notModified(&.{"\"a," ++ tag[1..]}, tag));
    // The list stops at an element that is not a tag.
    try testing.expect(!notModified(&.{"x, " ++ tag}, tag));
}

test "serversAt and serversMember: the document with servers after info, as the generator writes it" {
    const info = comptime tree.object(&.{.{ .key = "title", .value = .{ .string = "Todos API" } }});
    const paths = comptime tree.object(&.{});
    const without: Document = .{ .root = comptime tree.object(&.{
        .{ .key = "openapi", .value = .{ .string = "3.1.2" } },
        .{ .key = "info", .value = info },
        .{ .key = "paths", .value = paths },
    }), .runtime_prefix = true };
    const with: Document = .{ .root = comptime tree.object(&.{
        .{ .key = "openapi", .value = .{ .string = "3.1.2" } },
        .{ .key = "info", .value = info },
        .{ .key = "servers", .value = .{ .array = &.{tree.object(&.{.{ .key = "url", .value = .{ .string = "/a\"b" } }})} } },
        .{ .key = "paths", .value = paths },
    }) };
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.Io.Writer.Allocating = .init(arena);
    try without.write(&out.writer);
    const bytes = out.written();
    const at = serversAt(without).?;
    const spliced = try std.mem.concat(arena, u8, &.{ bytes[0..at], try serversMember(arena, "/a\"b"), bytes[at..] });
    var expected: std.Io.Writer.Allocating = .init(arena);
    try with.write(&expected.writer);
    try testing.expectEqualStrings(expected.written(), spliced);
    try testing.expectEqual(null, serversAt(.{ .root = .{ .string = "x" } }));
}

test {
    _ = @import("tests/docs_test.zig");
}
