//! The documents of the golden applications against their files in
//! golden/, in 3.1 and 3.2. Each application's requests get the statuses
//! they list, each of them a response of the operation that serves the
//! request in the document, picked as zefir-http's router picks a route; in
//! Debug the server also checks that each answer is one the route declares.
//! The build gives these tests the absolute path of golden/,
//! `golden_options.dir`, so they run in any directory; `zig build openapi`
//! runs them with ZEFIR_OPENAPI_UPDATE=1, which rewrites the files.
const std = @import("std");
const zefir = @import("zefir");
const http = zefir.http;
const Request = @import("apps/request.zig").Request;

const testing = std.testing;
const Node = @FieldType(zefir.openapi.Document, "root");
const golden = @import("golden_options").dir ++ std.fs.path.sep_str;

test "todos: the documents and the statuses of its requests" {
    try expectApp("todos", @import("apps/todos.zig"), "/api");
}

test "shapes: the documents and the statuses of its requests" {
    try expectApp("shapes", @import("apps/shapes.zig"), "/api");
}

test "rules: the documents and the statuses of its requests" {
    try expectApp("rules", @import("apps/rules.zig"), "/api");
}

test "secure: the documents and the statuses of its requests" {
    try expectApp("secure", @import("apps/secure.zig"), "/api");
}

test "the operation a request is checked against is the one zefir-http's router takes" {
    var backend: http.testing.Backend = .init(testing.allocator);
    defer backend.deinit();
    var service: @import("apps/secure.zig").Service = .{};
    try service.start(testing.allocator, testing.io, backend.backend());
    defer service.deinit(testing.io);
    const paths = member(service.docs_3_1.root, "paths").?;
    // A literal segment goes before a parameter.
    try expectServes(paths, "get", "/v1/projects/7/todos/export.csv", "/v1/projects/{projectId}/todos/export.csv");
    try expectServes(paths, "get", "/v1/projects/7/todos/count", "/v1/projects/{projectId}/todos/count");
    try expectServes(paths, "get", "/v1/projects/7/todos/events", "/v1/projects/{projectId}/todos/events");
    try expectServes(paths, "get", "/v1/projects/7/todos/1", "/v1/projects/{projectId}/todos/{id}");
    // A catch-all takes the rest of the path, one segment or more; a
    // parameter takes one.
    try expectServes(paths, "get", "/v1/projects/7/todos/files/docs/plan.txt", "/v1/projects/{projectId}/todos/files/{path}");
    try expectServes(paths, "get", "/v1/projects/7/todos/files/plan.txt", "/v1/projects/{projectId}/todos/files/{path}");
    try expectServes(paths, "get", "/v1/projects/7/todos/files", "/v1/projects/{projectId}/todos/{id}");
    try testing.expectEqual(null, find(paths, "get", "/v1/projects/7/todos/1/extra"));
    // A path without an operation of the method gives way to the next.
    try expectServes(paths, "delete", "/v1/projects/7/todos/export.csv", "/v1/projects/{projectId}/todos/{id}");
}

/// Starts the service of `App` on `http.testing`, compares its documents
/// with their files, and sends its requests, whose targets begin with
/// `prefix`.
fn expectApp(comptime name: []const u8, comptime App: type, comptime prefix: []const u8) !void {
    var backend: http.testing.Backend = .init(testing.allocator);
    defer backend.deinit();
    var service: App.Service = .{};
    try service.start(testing.allocator, testing.io, backend.backend());
    defer service.deinit(testing.io);
    try zefir.openapi.testing.expectFile(testing.io, service.docs_3_1, golden ++ name ++ "-3.1.json");
    try zefir.openapi.testing.expectFile(testing.io, service.docs_3_2, golden ++ name ++ "-3.2.json");
    for (App.requests) |req| {
        var res = try backend.request(testing.io, .{ .method = req.method, .target = req.target, .headers = req.headers, .body = req.body });
        defer res.deinit();
        if (res.status != req.status) {
            std.debug.print("{s}: {t} {s} answered {d}, not {d}: {s}\n", .{ name, req.method, req.target, res.status, req.status, res.body });
            return error.TestUnexpectedResult;
        }
        try expectDocumented(name, service.docs_3_1.root, prefix, req);
    }
}

/// The operation that serves `req` in the document lists its status.
fn expectDocumented(name: []const u8, root: Node, prefix: []const u8, req: Request) !void {
    const end = std.mem.findScalar(u8, req.target, '?') orelse req.target.len;
    const path = req.target[prefix.len..end];
    var method: [16]u8 = undefined;
    const found = find(member(root, "paths").?, std.ascii.lowerString(&method, @tagName(req.method)), path) orelse {
        std.debug.print("{s}: no operation of the document serves {t} {s}\n", .{ name, req.method, path });
        return error.TestUnexpectedResult;
    };
    var status: [3]u8 = undefined;
    _ = std.fmt.bufPrint(&status, "{d}", .{req.status}) catch unreachable;
    if (member(member(found.operation, "responses").?, &status) == null) {
        std.debug.print("{s}: {t} {s} answers {d}, which its operation, {s}, does not list\n", .{ name, req.method, path, req.status, found.template });
        return error.TestUnexpectedResult;
    }
}

/// `find` gives `path` the operation of `template`.
fn expectServes(paths: Node, method: []const u8, path: []const u8, template: []const u8) !void {
    const found = find(paths, method, path) orelse {
        std.debug.print("no operation of the document serves {s} {s}\n", .{ method, path });
        return error.TestUnexpectedResult;
    };
    try testing.expectEqualStrings(template, found.template);
}

fn member(node: Node, key: []const u8) ?Node {
    for (node.object) |m| {
        if (std.mem.eql(u8, m.key, key)) return m.value;
    }
    return null;
}

/// A path of the document and its operation of one method.
const Found = struct { template: []const u8, operation: Node };

/// The path of the document whose operation of `method` ("get") serves
/// `path`, as zefir-http's router picks it: at each segment a literal goes
/// first, then a parameter, then a catch-all, and a path without an
/// operation of `method` gives way to the next.
fn find(paths: Node, method: []const u8, path: []const u8) ?Found {
    var found: ?Found = null;
    for (paths.object) |m| {
        const candidate: Found = .{ .template = m.key, .operation = member(m.value, method) orelse continue };
        if (!matches(candidate, path)) continue;
        if (found == null or before(candidate, found.?)) found = candidate;
    }
    return found;
}

/// The kinds of segment of a path, in the order the router tries them.
const Kind = enum { literal, param, catch_all };

/// The document writes `{*name}` as `{name}`: a catch-all is the last
/// segment, whose parameter says that it takes the rest of the path.
fn kind(f: Found, segment: []const u8, last: bool) Kind {
    if (segment.len < 3 or segment[0] != '{') return .literal;
    if (last and takesRest(f.operation, segment[1 .. segment.len - 1])) return .catch_all;
    return .param;
}

/// Whether `f` serves `path`: a literal is the same segment, a parameter
/// one segment, a catch-all one segment or more.
fn matches(f: Found, path: []const u8) bool {
    var t = std.mem.splitScalar(u8, f.template, '/');
    var p = std.mem.splitScalar(u8, path, '/');
    while (t.next()) |segment| {
        const value = p.next() orelse return false;
        switch (kind(f, segment, t.peek() == null)) {
            .literal => if (!std.mem.eql(u8, segment, value)) return false,
            .param => {},
            .catch_all => return true,
        }
    }
    return p.next() == null;
}

/// Whether the router tries `a` before `b`, two paths of the document that
/// serve one path: at the first segment where their kinds differ, the
/// kind it tries first wins.
fn before(a: Found, b: Found) bool {
    var x = std.mem.splitScalar(u8, a.template, '/');
    var y = std.mem.splitScalar(u8, b.template, '/');
    while (x.next()) |s| {
        const t = y.next() orelse return false;
        const ka = kind(a, s, x.peek() == null);
        const kb = kind(b, t, y.peek() == null);
        if (ka != kb) return @backingInt(ka) < @backingInt(kb);
    }
    return false;
}

/// Whether the path parameter `name` of `operation` takes the rest of the
/// path: the document ends its description with the sentence that says so.
fn takesRest(operation: Node, name: []const u8) bool {
    const params = member(operation, "parameters") orelse return false;
    for (params.array) |p| {
        if (!std.mem.eql(u8, member(p, "in").?.string, "path") or !std.mem.eql(u8, member(p, "name").?.string, name)) continue;
        const description = member(p, "description") orelse return false;
        return std.mem.endsWith(u8, description.string, "The rest of the path, which may hold '/'.");
    }
    return false;
}
