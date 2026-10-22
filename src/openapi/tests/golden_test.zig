//! The documents of the golden applications against their files in
//! golden/, in 3.1 and 3.2. Each application's requests get the statuses
//! they list, each of them a response of the operation in the document; in
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

/// The operation of `req` in the document lists its status.
fn expectDocumented(name: []const u8, root: Node, prefix: []const u8, req: Request) !void {
    const end = std.mem.findScalar(u8, req.target, '?') orelse req.target.len;
    const path = req.target[prefix.len..end];
    const item = pathItem(member(root, "paths").?, path) orelse {
        std.debug.print("{s}: no path of the document matches {s}\n", .{ name, path });
        return error.TestUnexpectedResult;
    };
    var method: [16]u8 = undefined;
    const operation = member(item, std.ascii.lowerString(&method, @tagName(req.method))) orelse {
        std.debug.print("{s}: no operation {t} {s} in the document\n", .{ name, req.method, path });
        return error.TestUnexpectedResult;
    };
    var status: [3]u8 = undefined;
    _ = std.fmt.bufPrint(&status, "{d}", .{req.status}) catch unreachable;
    if (member(member(operation, "responses").?, &status) == null) {
        std.debug.print("{s}: {t} {s} answers {d}, which its operation does not list\n", .{ name, req.method, path, req.status });
        return error.TestUnexpectedResult;
    }
}

fn member(node: Node, key: []const u8) ?Node {
    for (node.object) |m| {
        if (std.mem.eql(u8, m.key, key)) return m.value;
    }
    return null;
}

/// The path of the document that `path` matches: one of as many segments,
/// else one whose last parameter takes the rest of the path.
fn pathItem(paths: Node, path: []const u8) ?Node {
    for ([_]bool{ false, true }) |rest| {
        for (paths.object) |m| {
            if (matches(m.key, path, rest)) return m.value;
        }
    }
    return null;
}

fn matches(template: []const u8, path: []const u8, rest: bool) bool {
    var t = std.mem.splitScalar(u8, template, '/');
    var p = std.mem.splitScalar(u8, path, '/');
    while (true) {
        const a = t.next() orelse return p.next() == null;
        const b = p.next() orelse return false;
        const param = a.len > 2 and a[0] == '{';
        if (param and rest and t.peek() == null) return true;
        if (!param and !std.mem.eql(u8, a, b)) return false;
    }
}
