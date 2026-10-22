//! zefir.openapi.Docs on the backend of zefir-http in memory: the document
//! at its route with its ETag and `Cache-Control: no-cache`, 304 for a
//! client that has it, HEAD, the page of Scalar with its pinned version and
//! hash, which finds the document at each path the router gives the page,
//! no page, a prefix that comes at run time, and two documents on two
//! paths. A document never holds the routes of `Docs`.
const std = @import("std");
const http = @import("http");
const openapi = @import("../openapi.zig");
const document_file = @import("../document.zig");
const Docs = @import("../Docs.zig").Docs;

const document = document_file.document;
const Document = document_file.Document;
const ControllerDoc = openapi.ControllerDoc;
const testing = std.testing;

// Application code of the tests: zefir ships no controller but Docs.
const TodosController = struct {
    pub const http_routes = http.routes(.{ .prefix = "/v1/todos", .methods = .{ .list = http.get("", .{}) } });

    pub const openapi: ControllerDoc(@This()) = .{ .tag = "Todos", .routes = .{ .list = .{ .summary = "List the todos" } } };

    pub fn list(_: *TodosController, _: *http.Context) error{}!http.Json([]const u64) {
        return .{ .value = &.{1} };
    }
};

const AdminController = struct {
    pub const http_routes = http.routes(.{ .prefix = "/v1/admin", .methods = .{ .stats = http.get("/stats", .{}) } });

    pub const openapi: ControllerDoc(@This()) = .{ .tag = "Admin", .routes = .{ .stats = .{ .summary = "The numbers of the service" } } };

    pub fn stats(_: *AdminController, _: *http.Context) error{}!http.Json(u64) {
        return .{ .value = 1 };
    }
};

/// A title the page must escape.
const info: openapi.DocumentOptions.Info = .{ .title = "Todos & lists <API>", .version = "1.0.0" };

/// A server of the todos and `Docs(.{})` under the prefix /api, known at
/// compile time.
const Fixture = struct {
    backend: http.testing.Backend,
    todos: TodosController = .{},
    docs: Docs(.{}) = undefined,
    server: http.Server = undefined,

    fn start(f: *Fixture) !void {
        f.backend = .init(testing.allocator);
        errdefer f.backend.deinit();
        const options = .{ .backend = f.backend.backend(), .prefix = "/api", .controllers = .{ &f.todos, &f.docs } };
        f.docs = try .init(testing.allocator, comptime document(@TypeOf(options), .{ .info = info }));
        errdefer f.docs.deinit(testing.allocator);
        f.server = try .init(testing.allocator, options);
        errdefer f.server.deinit(testing.io);
        try f.server.start(testing.io);
    }

    fn stop(f: *Fixture) void {
        f.server.deinit(testing.io);
        f.docs.deinit(testing.allocator);
        f.backend.deinit();
    }
};

fn get(backend: *http.testing.Backend, target: []const u8, headers: []const [2][]const u8) !http.testing.Response {
    return backend.request(testing.io, .{ .method = .GET, .target = target, .headers = headers });
}

/// The bytes of `d`, as `openapi.json` holds them.
fn written(d: Document) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try d.write(&out.writer);
    return out.toOwnedSlice();
}

/// The ETag of `bytes`: its Wyhash, as 16 hexadecimal digits in quotes.
fn etagOf(bytes: []const u8) [18]u8 {
    var tag: [18]u8 = undefined;
    _ = std.fmt.bufPrint(&tag, "\"{x:0>16}\"", .{std.hash.Wyhash.hash(0, bytes)}) catch unreachable;
    return tag;
}

/// The keys of `paths` of the document `body`, in order, are `expected`.
fn expectPaths(body: []const u8, expected: []const []const u8) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, body, .{});
    defer parsed.deinit();
    const paths = parsed.value.object.get("paths").?.object.keys();
    try testing.expectEqual(expected.len, paths.len);
    for (expected, paths) |want, have| try testing.expectEqualStrings(want, have);
}

test "GET of the document: its bytes as application/json, its ETag, no-cache; the document leaves Docs out" {
    var f: Fixture = .{ .backend = undefined };
    try f.start();
    defer f.stop();
    const bytes = try written(f.docs.document);
    defer testing.allocator.free(bytes);

    var res = try get(&f.backend, "/api/openapi.json", &.{});
    defer res.deinit();
    try testing.expectEqual(200, res.status);
    try testing.expectEqualStrings("application/json", res.header("content-type").?);
    try testing.expectEqualStrings(bytes, res.body);
    try testing.expectEqualStrings(&etagOf(bytes), res.header("etag").?);
    try testing.expectEqualStrings("no-cache", res.header("cache-control").?);
    // The prefix is known at compile time: it is in the document already.
    try testing.expect(std.mem.find(u8, res.body, "\"servers\": [\n    {\n      \"url\": \"/api\"\n    }\n  ]") != null);
    // Only the routes of the application: none of Docs.
    try expectPaths(res.body, &.{"/v1/todos"});
}

test "If-None-Match with the ETag: 304 without a body, with the ETag and no-cache; another tag: the document" {
    var f: Fixture = .{ .backend = undefined };
    try f.start();
    defer f.stop();
    const bytes = try written(f.docs.document);
    defer testing.allocator.free(bytes);
    const etag = etagOf(bytes);
    var weak_buffer: [32]u8 = undefined;
    const weak = try std.fmt.bufPrint(&weak_buffer, "W/{s}", .{&etag});
    var listed_buffer: [32]u8 = undefined;
    const listed = try std.fmt.bufPrint(&listed_buffer, "\"a,b\", {s}", .{&etag});

    const has: []const []const [2][]const u8 = &.{
        &.{.{ "if-none-match", &etag }},
        // The weak comparison: W/ does not matter.
        &.{.{ "if-none-match", weak }},
        // A tag in a list, after one with a comma in it.
        &.{.{ "if-none-match", listed }},
        // A tag in the second line of the field.
        &.{ .{ "if-none-match", "\"other\"" }, .{ "if-none-match", &etag } },
        &.{.{ "if-none-match", "*" }},
    };
    for (has) |headers| {
        var res = try get(&f.backend, "/api/openapi.json", headers);
        defer res.deinit();
        try testing.expectEqual(304, res.status);
        try testing.expectEqualStrings("", res.body);
        try testing.expectEqualStrings(&etag, res.header("etag").?);
        try testing.expectEqualStrings("no-cache", res.header("cache-control").?);
    }
    const has_not: []const []const [2][]const u8 = &.{
        &.{.{ "if-none-match", "\"other\"" }},
        &.{.{ "if-none-match", "W/\"other\", \"a,b\"" }},
        // The tag without its quotes is not the tag.
        &.{.{ "if-none-match", etag[1..17] }},
    };
    for (has_not) |headers| {
        var res = try get(&f.backend, "/api/openapi.json", headers);
        defer res.deinit();
        try testing.expectEqual(200, res.status);
        try testing.expectEqualStrings(bytes, res.body);
    }
}

test "HEAD of the document: the head of GET, without the body" {
    var f: Fixture = .{ .backend = undefined };
    try f.start();
    defer f.stop();
    const bytes = try written(f.docs.document);
    defer testing.allocator.free(bytes);

    var res = try f.backend.request(testing.io, .{ .method = .HEAD, .target = "/api/openapi.json" });
    defer res.deinit();
    try testing.expectEqual(200, res.status);
    try testing.expectEqualStrings("", res.body);
    try testing.expectEqualStrings("application/json", res.header("content-type").?);
    var length: [20]u8 = undefined;
    try testing.expectEqualStrings(try std.fmt.bufPrint(&length, "{d}", .{bytes.len}), res.header("content-length").?);
    try testing.expectEqualStrings(&etagOf(bytes), res.header("etag").?);
}

test "GET of the page: Scalar of the pinned version, checked by its hash, and the path of the document" {
    var f: Fixture = .{ .backend = undefined };
    try f.start();
    defer f.stop();

    var res = try get(&f.backend, "/api/docs", &.{});
    defer res.deinit();
    try testing.expectEqual(200, res.status);
    try testing.expectEqualStrings("text/html; charset=utf-8", res.header("content-type").?);
    try testing.expectEqualStrings(
        \\<!doctype html>
        \\<html>
        \\  <head>
        \\    <meta charset="utf-8">
        \\    <meta name="viewport" content="width=device-width, initial-scale=1">
        \\    <title>Todos &amp; lists &lt;API&gt;</title>
        \\  </head>
        \\  <body>
        \\    <script id="api-reference" data-url="/api/openapi.json"></script>
        \\    <script src="https://cdn.jsdelivr.net/npm/@scalar/api-reference@1.75.1/dist/browser/standalone.js" integrity="sha384-G+2Q2i9l3PPfmYkk0b4BAIUrs7xb/DNaTL1wCYYab4c9dIKlCyiqzC0Qx3eq9Wf6" crossorigin="anonymous"></script>
        \\  </body>
        \\</html>
        \\
    , res.body);
}

/// The path a browser fetches the document from, on the page at `page`:
/// the value of its `data-url`, relative to the page's directory unless it
/// begins with '/'.
fn documentPath(buf: []u8, page: []const u8, body: []const u8) ![]const u8 {
    const marker = "data-url=\"";
    const start = (std.mem.find(u8, body, marker) orelse return error.TestNoDataUrl) + marker.len;
    const url = body[start .. start + std.mem.findScalar(u8, body[start..], '"').?];
    if (url.len > 0 and url[0] == '/') return url;
    return std.fmt.bufPrint(buf, "{s}{s}", .{ page[0 .. std.mem.findScalarLast(u8, page, '/').? + 1], url });
}

/// The page at `page` gets 200, and the document it names too.
fn expectPageFindsDocument(backend: *http.testing.Backend, page: []const u8, document_path: []const u8) !void {
    var res = try get(backend, page, &.{});
    defer res.deinit();
    try testing.expectEqual(200, res.status);
    var buf: [256]u8 = undefined;
    const path = try documentPath(&buf, page, res.body);
    try testing.expectEqualStrings(document_path, path);
    var doc = try get(backend, path, &.{});
    defer doc.deinit();
    try testing.expectEqual(200, doc.status);
    try testing.expectEqualStrings("application/json", doc.header("content-type").?);
}

test "the page finds the document at each path the router gives it: a '/' at its end, a page at the prefix itself" {
    var f: Fixture = .{ .backend = undefined };
    try f.start();
    defer f.stop();
    try expectPageFindsDocument(&f.backend, "/api/docs", "/api/openapi.json");
    try expectPageFindsDocument(&f.backend, "/api/docs/", "/api/openapi.json");

    var backend: http.testing.Backend = .init(testing.allocator);
    defer backend.deinit();
    var todos: TodosController = .{};
    var docs: Docs(.{ .page = "/" }) = undefined;
    const options = .{ .backend = backend.backend(), .prefix = "/api", .controllers = .{ &todos, &docs } };
    docs = try .init(testing.allocator, comptime document(@TypeOf(options), .{ .info = info }));
    defer docs.deinit(testing.allocator);
    var server: http.Server = try .init(testing.allocator, options);
    defer server.deinit(testing.io);
    try server.start(testing.io);
    try expectPageFindsDocument(&backend, "/api", "/api/openapi.json");
    try expectPageFindsDocument(&backend, "/api/", "/api/openapi.json");
}

test ".page = null: no page; the document stays" {
    var backend: http.testing.Backend = .init(testing.allocator);
    defer backend.deinit();
    var todos: TodosController = .{};
    var docs: Docs(.{ .page = null }) = undefined;
    const options = .{ .backend = backend.backend(), .prefix = "/api", .controllers = .{ &todos, &docs } };
    docs = try .init(testing.allocator, comptime document(@TypeOf(options), .{ .info = info }));
    defer docs.deinit(testing.allocator);
    var server: http.Server = try .init(testing.allocator, options);
    defer server.deinit(testing.io);
    try server.start(testing.io);

    var page = try get(&backend, "/api/docs", &.{});
    defer page.deinit();
    try testing.expectEqual(404, page.status);
    var doc = try get(&backend, "/api/openapi.json", &.{});
    defer doc.deinit();
    try testing.expectEqual(200, doc.status);
}

test "a prefix from the config: servers holds the prefix it serves, right after info, and the ETag is of those bytes" {
    var backend: http.testing.Backend = .init(testing.allocator);
    defer backend.deinit();
    var todos: TodosController = .{};
    var docs: Docs(.{}) = undefined;
    // As from a config: the prefix is not known at compile time.
    var prefix: []const u8 = "/api";
    _ = &prefix;
    const options = .{ .backend = backend.backend(), .prefix = prefix, .controllers = .{ &todos, &docs } };
    docs = try .init(testing.allocator, comptime document(@TypeOf(options), .{ .info = info }));
    defer docs.deinit(testing.allocator);
    try testing.expect(docs.document.runtime_prefix);
    var server: http.Server = try .init(testing.allocator, options);
    defer server.deinit(testing.io);
    try server.start(testing.io);

    // The document of the same server, its prefix known at compile time.
    const Known = @TypeOf(.{ .backend = backend.backend(), .prefix = "/api", .controllers = .{ &todos, &docs } });
    const known = try written(comptime document(Known, .{ .info = info }));
    defer testing.allocator.free(known);
    const without = try written(docs.document);
    defer testing.allocator.free(without);
    try testing.expect(std.mem.find(u8, without, "\"servers\"") == null);

    var res = try get(&backend, "/api/openapi.json", &.{});
    defer res.deinit();
    try testing.expectEqual(200, res.status);
    try testing.expectEqualStrings(known, res.body);
    const etag = etagOf(known);
    try testing.expectEqualStrings(&etag, res.header("etag").?);
    try testing.expect(!std.mem.eql(u8, &etag, &etagOf(without)));
    var again = try get(&backend, "/api/openapi.json", &.{.{ "if-none-match", &etag }});
    defer again.deinit();
    try testing.expectEqual(304, again.status);
    // The page names the document by the prefix it serves.
    try expectPageFindsDocument(&backend, "/api/docs/", "/api/openapi.json");
}

test "an empty prefix from the config: no servers" {
    var backend: http.testing.Backend = .init(testing.allocator);
    defer backend.deinit();
    var todos: TodosController = .{};
    var docs: Docs(.{}) = undefined;
    var prefix: []const u8 = "";
    _ = &prefix;
    const options = .{ .backend = backend.backend(), .prefix = prefix, .controllers = .{ &todos, &docs } };
    docs = try .init(testing.allocator, comptime document(@TypeOf(options), .{ .info = info }));
    defer docs.deinit(testing.allocator);
    var server: http.Server = try .init(testing.allocator, options);
    defer server.deinit(testing.io);
    try server.start(testing.io);

    const bytes = try written(docs.document);
    defer testing.allocator.free(bytes);
    var res = try get(&backend, "/openapi.json", &.{});
    defer res.deinit();
    try testing.expectEqualStrings(bytes, res.body);
    try testing.expectEqualStrings(&etagOf(bytes), res.header("etag").?);
}

test "two Docs on two paths serve two documents, each with its page" {
    var backend: http.testing.Backend = .init(testing.allocator);
    defer backend.deinit();
    var todos: TodosController = .{};
    var admin: AdminController = .{};
    var public: Docs(.{}) = undefined;
    var internal: Docs(.{ .json = "/internal/openapi.json", .page = "/internal/docs" }) = undefined;
    const options = .{ .backend = backend.backend(), .prefix = "/api", .controllers = .{ &todos, &admin, &public, &internal } };
    public = try .init(testing.allocator, comptime document(@TypeOf(options), .{ .info = info, .exclude = &.{AdminController} }));
    defer public.deinit(testing.allocator);
    internal = try .init(testing.allocator, comptime document(@TypeOf(options), .{ .info = info, .include = &.{AdminController} }));
    defer internal.deinit(testing.allocator);
    var server: http.Server = try .init(testing.allocator, options);
    defer server.deinit(testing.io);
    try server.start(testing.io);

    var outside = try get(&backend, "/api/openapi.json", &.{});
    defer outside.deinit();
    try expectPaths(outside.body, &.{"/v1/todos"});
    var inside = try get(&backend, "/api/internal/openapi.json", &.{});
    defer inside.deinit();
    try expectPaths(inside.body, &.{"/v1/admin/stats"});
    try testing.expect(!std.mem.eql(u8, outside.header("etag").?, inside.header("etag").?));
    try expectPageFindsDocument(&backend, "/api/internal/docs", "/api/internal/openapi.json");
    try expectPageFindsDocument(&backend, "/api/docs", "/api/openapi.json");
}
