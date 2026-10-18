//! The router: the routes of all controllers in one
//! trie of path segments, built at compile time. A pattern is literal
//! segments, `{name}` (one segment) and `{*name}` (the rest of the path,
//! one segment or more, last only). Two routes of one method whose
//! patterns have the same shape stop the build, and so does a pattern that
//! does not parse.
//!
//! A request is matched on its normalized path (path.zig), after the
//! server's prefix, which is known only at run time. At each node the
//! literal child goes first, then the parameter, then the catch-all, and a
//! branch that ends without a route of the method gives way to the next
//! one: `/export.csv` wins over `/{id}`, and `/a/b/d` still finds
//! `/a/{x}/d` next to `/a/b/c`. A GET route serves HEAD on its path,
//! unless it is SSE or the path has a HEAD route of its own; OPTIONS
//! without an `http.options` route gets the server's 204 with `Allow`. A
//! path that routes have, but none of the request's method, is 405 with
//! `Allow`; else 404.
const std = @import("std");
const routes = @import("routes.zig");
const path_rules = @import("path.zig");
const Normalized = path_rules.Normalized;

/// The methods a route can have, in the order of `Allow`.
pub const methods = [_]std.http.Method{ .GET, .HEAD, .POST, .PUT, .PATCH, .DELETE, .OPTIONS };

const get_index = methodIndex(.GET).?;
const head_index = methodIndex(.HEAD).?;
const options_index = methodIndex(.OPTIONS).?;

/// The place of `method` in `methods`; null for a method no route has.
pub fn methodIndex(method: std.http.Method) ?u3 {
    return switch (method) {
        .GET => 0,
        .HEAD => 1,
        .POST => 2,
        .PUT => 3,
        .PATCH => 4,
        .DELETE => 5,
        .OPTIONS => 6,
        else => null,
    };
}

/// A set of methods, for the `Allow` header.
pub const Allow = struct {
    bits: u8 = 0,

    pub fn has(a: Allow, method: std.http.Method) bool {
        const i = methodIndex(method) orelse return false;
        return a.bits & (@as(u8, 1) << i) != 0;
    }

    /// The value of `Allow`: "GET, HEAD, POST, OPTIONS".
    pub fn header(a: Allow) []const u8 {
        return allow_headers[a.bits & 0x7f];
    }
};

const allow_headers: [128][]const u8 = table: {
    @setEvalBranchQuota(10_000);
    var table: [128][]const u8 = undefined;
    for (&table, 0..) |*slot, bits| {
        var text: []const u8 = "";
        for (methods, 0..) |m, i| {
            if (bits & (1 << i) == 0) continue;
            text = text ++ (if (text.len == 0) "" else ", ") ++ @tagName(m);
        }
        slot.* = text;
    }
    const final = table;
    break :table final;
};

/// One segment of a route's pattern.
pub const Segment = union(enum) {
    literal: []const u8,
    /// `{name}`: one segment of the path.
    param: []const u8,
    /// `{*name}`: the rest of the path, one segment or more.
    catch_all: []const u8,
};

/// The segments of `pattern`, the controller's prefix and the route's
/// path ("" is the root, as is "/"; a trailing slash does not count), or a
/// compile error that names the route (`where`, "UsersV1Controller.get"):
/// an unclosed `{`, a parameter that is not a whole segment, a name that is
/// not 1 to 64 of `A-Z a-z 0-9 _ -` or comes twice, `{*name}` before the
/// last segment, an empty segment, a dot segment, a literal segment with a
/// byte that is not visible ASCII or is '%', '?' or '#'.
pub fn parse(comptime pattern: []const u8, comptime where: []const u8) []const Segment {
    if (pattern.len == 0) return &.{};
    const head = "zefir.http: " ++ where ++ ": route path \"" ++ pattern ++ "\"";
    var out: []const Segment = &.{};
    var names: []const []const u8 = &.{};
    var rest_name: ?[]const u8 = null;
    var it = std.mem.splitScalar(u8, pattern[1..], '/');
    while (it.next()) |s| {
        if (s.len == 0 and it.index == null) break;
        if (rest_name) |name| @compileError("zefir.http: " ++ where ++ ": {*" ++ name ++ "} must be the last segment of \"" ++ pattern ++ "\"");
        if (s.len == 0) @compileError(head ++ " has an empty segment");
        if (s[0] != '{') {
            if (std.mem.findAny(u8, s, "{}") != null) @compileError(head ++ ": a parameter is a whole segment, such as /{id}");
            if (std.mem.eql(u8, s, ".") or std.mem.eql(u8, s, ".."))
                @compileError(head ++ " has a dot segment, which a request path never keeps");
            for (s) |c| if (!path_rules.literalByte(c))
                @compileError(head ++ ": a segment is visible ASCII without '%', '?' and '#', written as the path reads decoded");
            out = out ++ [_]Segment{.{ .literal = s }};
            continue;
        }
        const close = std.mem.findScalar(u8, s, '}') orelse @compileError(head ++ " has an unclosed {");
        if (close != s.len - 1 or std.mem.findScalar(u8, s[1..], '{') != null)
            @compileError(head ++ ": a parameter is a whole segment, such as /{id}");
        const inner = s[1 .. s.len - 1];
        const is_rest = inner.len > 0 and inner[0] == '*';
        const name = if (is_rest) inner[1..] else inner;
        if (!validName(name))
            @compileError("zefir.http: " ++ where ++ ": " ++ s ++ " is not a parameter name: 1 to 64 characters from A-Z, a-z, 0-9, '_' and '-'");
        for (names) |other| {
            if (std.mem.eql(u8, other, name)) @compileError(head ++ " names {" ++ name ++ "} twice");
        }
        names = names ++ [_][]const u8{name};
        if (is_rest) {
            rest_name = name;
            out = out ++ [_]Segment{.{ .catch_all = name }};
        } else out = out ++ [_]Segment{.{ .param = name }};
    }
    return out;
}

fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') return false;
    }
    return true;
}

/// The names of the parameters of `segments`, in order.
pub fn paramNames(comptime segments: []const Segment) []const []const u8 {
    var names: []const []const u8 = &.{};
    for (segments) |s| switch (s) {
        .literal => {},
        .param, .catch_all => |name| names = names ++ [_][]const u8{name},
    };
    return names;
}

/// What the trie needs of a route.
pub const Spec = struct {
    method: std.http.Method,
    kind: routes.Kind,
    segments: []const Segment,
    /// For messages: the route, "UsersV1Controller.get", and its pattern
    /// as declared.
    name: []const u8,
    pattern: []const u8,
};

/// No route or no child.
pub const none = std.math.maxInt(u32);

pub const Node = struct {
    literals: []const Literal = &.{},
    param: u32 = none,
    catch_all: u32 = none,
    /// The route that ends here for each of `methods`, by its index in the
    /// list given to `build`; `none` where there is none.
    routes: [methods.len]u32 = @splat(none),
    /// The GET route here is SSE: it does not serve HEAD.
    sse_get: bool = false,
    /// The methods of the path that ends here: its routes, HEAD with a GET
    /// that is not SSE, and OPTIONS. Empty without a route.
    allow: Allow = .{},
};

pub const Literal = struct { segment: []const u8, node: u32 };

/// The trie of `specs`, node 0 the root. Two specs of one method on one
/// shape (`/{id}` and `/{name}` are one) stop the build with a message
/// that names both.
pub fn build(comptime specs: []const Spec) []const Node {
    var upper: usize = 1;
    for (specs) |s| upper += s.segments.len;
    var nodes: [upper]Node = @splat(.{});
    var len: u32 = 1;
    for (specs, 0..) |s, index| {
        var at: u32 = 0;
        for (s.segments) |segment| switch (segment) {
            .literal => |literal| {
                at = for (nodes[at].literals) |l| {
                    if (std.mem.eql(u8, l.segment, literal)) break l.node;
                } else child: {
                    nodes[at].literals = nodes[at].literals ++ [_]Literal{.{ .segment = literal, .node = len }};
                    len += 1;
                    break :child len - 1;
                };
            },
            .param => {
                if (nodes[at].param == none) {
                    nodes[at].param = len;
                    len += 1;
                }
                at = nodes[at].param;
            },
            .catch_all => {
                if (nodes[at].catch_all == none) {
                    nodes[at].catch_all = len;
                    len += 1;
                }
                at = nodes[at].catch_all;
            },
        };
        const m = methodIndex(s.method) orelse @compileError("zefir.http: " ++ s.name ++ ": no route has the method " ++ @tagName(s.method));
        const taken = nodes[at].routes[m];
        if (taken != none) {
            const first = specs[taken];
            const method = @tagName(s.method);
            @compileError("zefir.http: " ++ first.name ++ " (" ++ method ++ " " ++ display(first.pattern) ++ ") and " ++
                s.name ++ " (" ++ method ++ " " ++ display(s.pattern) ++ ") match the same requests");
        }
        nodes[at].routes[m] = @intCast(index);
        if (s.kind == .sse) nodes[at].sse_get = true;
    }
    for (nodes[0..len]) |*n| n.allow = allowOf(n.*);
    const final: [len]Node = nodes[0..len].*;
    return &final;
}

/// A pattern as messages print it: the root is "/".
pub fn display(comptime pattern: []const u8) []const u8 {
    return if (pattern.len == 0) "/" else pattern;
}

fn allowOf(n: Node) Allow {
    var bits: u8 = 0;
    for (n.routes, 0..) |r, i| {
        if (r != none) bits |= @as(u8, 1) << @intCast(i);
    }
    if (bits == 0) return .{};
    if (n.routes[get_index] != none and !n.sse_get) bits |= 1 << head_index;
    return .{ .bits = bits | 1 << options_index };
}

/// The result of `Router.match`.
pub const Match = union(enum) {
    found: Found,
    /// Routes have the path, none the method: 405 with `Allow`.
    method_not_allowed: Allow,
    /// OPTIONS on a path without an `http.options` route: the server's
    /// 204 with `Allow`.
    options: Allow,
    not_found,
};

pub const Found = struct {
    /// The route: its index in the list given to `build`, the server's
    /// table; for HEAD, the path's GET route, unless it has a HEAD route.
    route: u32,
    /// The values of the route's parameters, in the order of its pattern:
    /// slices of the path's segments (`{*rest}`: of several, joined by '/').
    params: []const []const u8,
};

/// The trie at run time, with the server's prefix.
pub const Router = struct {
    nodes: []const Node,
    /// The server's prefix, "" or such as "/api": segments without '%', as
    /// `Server.init` checks.
    prefix: []const u8 = "",
    /// The most parameters a route has: how long `values` of `match` is.
    max_params: usize = 0,

    /// The route of `method` on `path`; the values of its parameters go to
    /// `values` (at least `max_params` long), which the result points into.
    pub fn match(r: *const Router, method: std.http.Method, path: Normalized, values: [][]const u8) Match {
        std.debug.assert(values.len >= r.max_params);
        if (path.empty_segment) return .not_found;
        const first = afterPrefix(r.prefix, path.segments) orelse return .not_found;
        if (methodIndex(method)) |m| {
            const search: Search = .{ .nodes = r.nodes, .path = path, .method = m, .values = values };
            if (search.find(0, first, 0)) |found| return .{ .found = found };
        }
        var allow: Allow = .{};
        collect(r.nodes, path, 0, first, &allow);
        if (allow.bits == 0) return .not_found;
        if (method == .OPTIONS) return .{ .options = allow };
        return .{ .method_not_allowed = allow };
    }

    /// The methods of all routes, for `OPTIONS *`, which asks about the
    /// server rather than a path.
    pub fn serverAllow(r: *const Router) Allow {
        var allow: Allow = .{};
        for (r.nodes) |n| allow.bits |= n.allow.bits;
        return allow;
    }
};

/// The index of the first segment after `prefix`, or null when the path
/// does not start with it.
fn afterPrefix(prefix: []const u8, segments: []const []const u8) ?usize {
    if (prefix.len == 0) return 0;
    var i: usize = 0;
    var it = std.mem.splitScalar(u8, prefix[1..], '/');
    while (it.next()) |p| : (i += 1) {
        if (i == segments.len or !std.mem.eql(u8, p, segments[i])) return null;
    }
    return i;
}

const Search = struct {
    nodes: []const Node,
    path: Normalized,
    method: u3,
    values: [][]const u8,

    /// The first route in priority order below node `at`, which the path
    /// reached with segment `i` and `p` parameters.
    fn find(s: *const Search, at: u32, i: usize, p: usize) ?Found {
        const node = &s.nodes[at];
        const segments = s.path.segments;
        if (i == segments.len) return s.ends(node, p);
        for (node.literals) |l| {
            if (!std.mem.eql(u8, l.segment, segments[i])) continue;
            if (s.find(l.node, i + 1, p)) |found| return found;
            break;
        }
        if (node.param != none) {
            s.values[p] = segments[i];
            if (s.find(node.param, i + 1, p + 1)) |found| return found;
        }
        if (node.catch_all != none) {
            s.values[p] = s.path.rest(i);
            if (s.ends(&s.nodes[node.catch_all], p + 1)) |found| return found;
        }
        return null;
    }

    fn ends(s: *const Search, node: *const Node, p: usize) ?Found {
        const own = node.routes[s.method];
        if (own != none) return .{ .route = own, .params = s.values[0..p] };
        const get = node.routes[get_index];
        if (s.method == head_index and get != none and !node.sse_get) return .{ .route = get, .params = s.values[0..p] };
        return null;
    }
};

/// The methods of every node the path reaches.
fn collect(nodes: []const Node, path: Normalized, at: u32, i: usize, allow: *Allow) void {
    const node = &nodes[at];
    const segments = path.segments;
    if (i == segments.len) {
        allow.bits |= node.allow.bits;
        return;
    }
    for (node.literals) |l| {
        if (!std.mem.eql(u8, l.segment, segments[i])) continue;
        collect(nodes, path, l.node, i + 1, allow);
        break;
    }
    if (node.param != none) collect(nodes, path, node.param, i + 1, allow);
    if (node.catch_all != none) allow.bits |= nodes[node.catch_all].allow.bits;
}

const testing = std.testing;
const normalize = @import("path.zig").normalize;

const Row = struct { std.http.Method, routes.Kind, []const u8 };

fn specsOf(comptime rows: []const Row) []const Spec {
    var specs: []const Spec = &.{};
    for (rows, 0..) |row, i| {
        const name = std.fmt.comptimePrint("route{d}", .{i});
        specs = specs ++ [_]Spec{.{ .method = row[0], .kind = row[1], .segments = parse(row[2], name), .name = name, .pattern = row[2] }};
    }
    return specs;
}

fn routerOf(comptime rows: []const Row, prefix: []const u8) Router {
    const specs = comptime specsOf(rows);
    comptime var max: usize = 0;
    inline for (specs) |s| max = @max(max, comptime paramNames(s.segments).len);
    return .{ .nodes = comptime build(specs), .prefix = prefix, .max_params = max };
}

/// A test request: the router's answer and the arena its values live in.
const Probe = struct {
    arena: std.heap.ArenaAllocator,
    values: [8][]const u8 = undefined,

    fn match(probe: *Probe, r: *const Router, method: std.http.Method, raw: []const u8) !Match {
        const n = try normalize(probe.arena.allocator(), raw);
        return r.match(method, n, &probe.values);
    }
};

fn expectFound(m: Match, route: u32, params: []const []const u8) !void {
    try testing.expect(m == .found);
    try testing.expectEqual(route, m.found.route);
    try testing.expectEqual(params.len, m.found.params.len);
    for (params, m.found.params) |want, got| try testing.expectEqualStrings(want, got);
}

test "router: literal beats parameter beats catch-all, with backtracking" {
    const r = routerOf(&.{
        .{ .GET, .rest, "/a/b/c" },
        .{ .GET, .rest, "/a/{x}/d" },
        .{ .GET, .rest, "/a/{*rest}" },
        .{ .GET, .rest, "/export.csv" },
        .{ .GET, .rest, "/{id}" },
    }, "");
    var probe: Probe = .{ .arena = .init(testing.allocator) };
    defer probe.arena.deinit();
    try expectFound(try probe.match(&r, .GET, "/a/b/c"), 0, &.{});
    try expectFound(try probe.match(&r, .GET, "/a/b/d"), 1, &.{"b"});
    try expectFound(try probe.match(&r, .GET, "/a/b/e/f"), 2, &.{"b/e/f"});
    try expectFound(try probe.match(&r, .GET, "/a/b"), 2, &.{"b"});
    try expectFound(try probe.match(&r, .GET, "/export.csv"), 3, &.{});
    try expectFound(try probe.match(&r, .GET, "/42"), 4, &.{"42"});
    // A catch-all takes one segment or more, never none.
    try expectFound(try probe.match(&r, .GET, "/a"), 4, &.{"a"});
    try testing.expectEqual(Match.not_found, try probe.match(&r, .GET, "/"));
    // %2F inside a parameter stays a slash in its value.
    try expectFound(try probe.match(&r, .GET, "/a%2Fb"), 4, &.{"a/b"});
    try expectFound(try probe.match(&r, .GET, "/a/x%2Fy/d"), 1, &.{"x/y"});
    // Case matters, a trailing slash does not, // matches nothing.
    try testing.expectEqual(Match.not_found, try probe.match(&r, .GET, "/A/b/c/d"));
    try expectFound(try probe.match(&r, .GET, "/a/b/c/"), 0, &.{});
    try testing.expectEqual(Match.not_found, try probe.match(&r, .GET, "/a//b/c"));
}

test "router: a branch gives way when the method is not there" {
    const r = routerOf(&.{
        .{ .GET, .rest, "/users/me" },
        .{ .DELETE, .rest, "/users/{id}" },
    }, "");
    var probe: Probe = .{ .arena = .init(testing.allocator) };
    defer probe.arena.deinit();
    try expectFound(try probe.match(&r, .DELETE, "/users/me"), 1, &.{"me"});
    try expectFound(try probe.match(&r, .GET, "/users/me"), 0, &.{});
    const m = try probe.match(&r, .GET, "/users/7");
    try testing.expectEqualStrings("DELETE, OPTIONS", m.method_not_allowed.header());
}

test "router: 405 with Allow; HEAD with GET but not with SSE; OPTIONS lists Allow" {
    const r = routerOf(&.{
        .{ .GET, .rest, "/users" },
        .{ .POST, .rest, "/users" },
        .{ .GET, .sse, "/events" },
        .{ .GET, .rest, "/items/{id}" },
        .{ .DELETE, .rest, "/items/{id}" },
        .{ .OPTIONS, .rest, "/items/{id}" },
        .{ .GET, .rest, "/files" },
        .{ .HEAD, .rest, "/files" },
        .{ .PUT, .rest, "/docs/{*path}" },
        .{ .PATCH, .rest, "/docs/{name}" },
    }, "");
    var probe: Probe = .{ .arena = .init(testing.allocator) };
    defer probe.arena.deinit();

    // 405: the methods of the path, in a fixed order, HEAD with GET.
    var m = try probe.match(&r, .PUT, "/users");
    try testing.expectEqualStrings("GET, HEAD, POST, OPTIONS", m.method_not_allowed.header());
    m = try probe.match(&r, .TRACE, "/users");
    try testing.expectEqualStrings("GET, HEAD, POST, OPTIONS", m.method_not_allowed.header());
    // The Allow of a path is that of every route its path matches.
    m = try probe.match(&r, .GET, "/docs/a");
    try testing.expectEqualStrings("PUT, PATCH, OPTIONS", m.method_not_allowed.header());
    m = try probe.match(&r, .GET, "/docs/a/b");
    try testing.expectEqualStrings("PUT, OPTIONS", m.method_not_allowed.header());

    // HEAD: served by GET without a body, unless the GET is SSE or the
    // path has a HEAD route of its own.
    try expectFound(try probe.match(&r, .HEAD, "/users"), 0, &.{});
    try expectFound(try probe.match(&r, .HEAD, "/items/9"), 3, &.{"9"});
    try expectFound(try probe.match(&r, .HEAD, "/files"), 7, &.{});
    try expectFound(try probe.match(&r, .GET, "/events"), 2, &.{});
    m = try probe.match(&r, .HEAD, "/events");
    try testing.expectEqualStrings("GET, OPTIONS", m.method_not_allowed.header());
    try testing.expect(!m.method_not_allowed.has(.HEAD));

    // OPTIONS: the server's answer lists Allow, an http.options route
    // answers on its own path.
    m = try probe.match(&r, .OPTIONS, "/users");
    try testing.expectEqualStrings("GET, HEAD, POST, OPTIONS", m.options.header());
    m = try probe.match(&r, .OPTIONS, "/events");
    try testing.expectEqualStrings("GET, OPTIONS", m.options.header());
    try expectFound(try probe.match(&r, .OPTIONS, "/items/9"), 5, &.{"9"});
    m = try probe.match(&r, .POST, "/items/9");
    try testing.expectEqualStrings("GET, HEAD, DELETE, OPTIONS", m.method_not_allowed.header());

    // 404: no route has the path.
    try testing.expectEqual(Match.not_found, try probe.match(&r, .GET, "/nothing"));
    try testing.expectEqual(Match.not_found, try probe.match(&r, .OPTIONS, "/nothing"));
    try testing.expectEqual(Match.not_found, try probe.match(&r, .GET, "/items"));

    // OPTIONS * asks about the whole server.
    try testing.expectEqualStrings("GET, HEAD, POST, PUT, PATCH, DELETE, OPTIONS", r.serverAllow().header());
    const sse_only = routerOf(&.{.{ .GET, .sse, "/events" }}, "");
    try testing.expectEqualStrings("GET, OPTIONS", sse_only.serverAllow().header());
}

test "router: the server prefix is given at run time" {
    const rows = [_]Row{
        .{ .GET, .rest, "" },
        .{ .GET, .rest, "/v1/todos/{id}" },
    };
    var probe: Probe = .{ .arena = .init(testing.allocator) };
    defer probe.arena.deinit();
    for ([_][]const u8{ "/api", "/api/v2", "" }) |prefix| {
        const r = routerOf(&rows, prefix);
        var buf: [64]u8 = undefined;
        try expectFound(try probe.match(&r, .GET, try std.fmt.bufPrint(&buf, "{s}/", .{prefix})), 0, &.{});
        try expectFound(try probe.match(&r, .GET, try std.fmt.bufPrint(&buf, "{s}/v1/todos/7", .{prefix})), 1, &.{"7"});
        if (prefix.len > 0) {
            try expectFound(try probe.match(&r, .GET, prefix), 0, &.{});
            try testing.expectEqual(Match.not_found, try probe.match(&r, .GET, "/v1/todos/7"));
            try testing.expectEqual(Match.not_found, try probe.match(&r, .GET, "/API/v1/todos/7"));
        }
    }
    const r = routerOf(&rows, "/api");
    try testing.expectEqual(Match.not_found, try probe.match(&r, .GET, "/apiv1/todos/7"));
    // The prefix is matched on decoded segments.
    try expectFound(try probe.match(&r, .GET, "/%61pi/v1/todos/7"), 1, &.{"7"});
}

test "router: the segments of a pattern" {
    const segments = comptime parse("/v1/files/{id}/{*rest}/", "C.files");
    try testing.expectEqual(4, segments.len);
    try testing.expectEqualStrings("v1", segments[0].literal);
    try testing.expectEqualStrings("id", segments[2].param);
    try testing.expectEqualStrings("rest", segments[3].catch_all);
    try testing.expectEqual(0, comptime parse("", "C.root").len);
    try testing.expectEqual(0, comptime parse("/", "C.root").len);
    const names = comptime paramNames(parse("/a/{a-b_C9}/{*z}", "C.x"));
    try testing.expectEqualStrings("a-b_C9", names[0]);
    try testing.expectEqualStrings("z", names[1]);
    try testing.expectEqualStrings("GET, HEAD, POST, PUT, PATCH, DELETE, OPTIONS", (Allow{ .bits = 0x7f }).header());
}
