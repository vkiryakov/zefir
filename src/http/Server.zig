//! `http.Server` (design section 4): one type for every application.
//! `init` does the compile-time work over its options (plan.zig): it reads
//! the routes of the controllers, checks them and builds the router's trie;
//! at run time it copies the server's prefix and keeps the table of routes.
//!
//! ```zig
//! var server = try http.Server.init(gpa, .{
//!     .backend = native.backend(),
//!     .prefix = "/api", // only for controllers; may come from the config
//!     .controllers = .{ &todos_v1, &health },
//! });
//! defer server.deinit(io);
//! ```
//!
//! The compiler checks every controller where it is passed to `init`: a
//! pointer to a mutable instance, `pub const http_routes =
//! http.routes(.{ ... })`, a `pub fn` of the right form for each route,
//! patterns that parse and no two routes of one method on one path. Zig
//! checks only what is used, so an application keeps a test that builds
//! its server: then `zig build test` runs the checks too.
const std = @import("std");
const Backend = @import("Backend.zig");
const plan = @import("plan.zig");
const route_decls = @import("routes.zig");
const routing = @import("router.zig");

const Server = @This();

gpa: std.mem.Allocator,
backend: Backend,
/// The server's prefix, copied: it may come from the config.
prefix: []const u8,
/// The routes of all controllers, in the order of `.controllers`, each in
/// the order of its `.methods`; `router` gives indices into it.
routes: []Route,
router: routing.Router,

/// `InvalidConfiguration`: a `.prefix` that is not empty and not such as
/// "/api" or "/api/v2" (segments of visible ASCII, without `%`, `?`, `#`,
/// `{` and `}`, no empty or dot segments, no trailing slash).
pub const InitError = error{ InvalidConfiguration, OutOfMemory };

/// One route at run time.
pub const Route = struct {
    /// The method, the full pattern with the server's prefix, the
    /// controller and its method, as `ctx.route()` gives them.
    info: route_decls.RouteInfo,
    kind: route_decls.Kind,
    /// The controller the handler runs on, borrowed.
    controller: *anyopaque,
    /// The names of the pattern's parameters, in the order of the values
    /// the router gives.
    params: []const []const u8,
    /// Instead of the server's `.max_body_bytes`.
    max_body_bytes: ?usize,
    timeout: route_decls.Timeout,
    heartbeat: ?std.Io.Duration,
};

/// Builds a server from `options`, a struct literal: `.backend` and
/// `.controllers` (a tuple of pointers to controllers, at least one), and
/// optionally `.prefix` (before the routes of the controllers, such as
/// "/api"). The controllers are borrowed and live as long as the server;
/// the prefix is copied. No I/O.
pub fn init(gpa: std.mem.Allocator, options: anytype) InitError!Server {
    const O = @TypeOf(options);
    const p = comptime plan.of(O);
    // The loop below unrolls once per route.
    @setEvalBranchQuota(1000 + 100 * p.routes.len);

    const given: []const u8 = if (@hasField(O, "prefix")) options.prefix else "";
    if (!validPrefix(given)) return error.InvalidConfiguration;
    const prefix = try gpa.dupe(u8, given);
    errdefer gpa.free(prefix);

    const table = try gpa.alloc(Route, p.routes.len);
    errdefer gpa.free(table);
    var filled: usize = 0;
    errdefer for (table[0..filled]) |r| gpa.free(r.info.pattern);
    inline for (p.routes, 0..) |r, i| {
        const pattern = if (prefix.len + r.pattern.len == 0)
            try gpa.dupe(u8, "/")
        else
            try std.mem.concat(gpa, u8, &.{ prefix, r.pattern });
        table[i] = .{
            .info = .{ .method = r.method, .pattern = pattern, .controller = r.controller_name, .handler = r.handler },
            .kind = r.kind,
            .controller = options.controllers[r.controller_index],
            .params = r.params,
            .max_body_bytes = r.max_body_bytes,
            .timeout = r.timeout,
            .heartbeat = r.heartbeat,
        };
        filled += 1;
    }

    return .{
        .gpa = gpa,
        .backend = options.backend,
        .prefix = prefix,
        .routes = table,
        .router = .{ .nodes = p.nodes, .prefix = prefix, .max_params = p.max_params },
    };
}

/// Frees the tables.
pub fn deinit(server: *Server, io: std.Io) void {
    _ = io;
    for (server.routes) |r| server.gpa.free(r.info.pattern);
    server.gpa.free(server.routes);
    server.gpa.free(server.prefix);
    server.* = undefined;
}

/// "" or "/api", "/api/v2": what the router compares, segment by segment,
/// with the decoded segments of a path.
fn validPrefix(prefix: []const u8) bool {
    if (prefix.len == 0) return true;
    if (prefix[0] != '/') return false;
    var it = std.mem.splitScalar(u8, prefix[1..], '/');
    while (it.next()) |s| {
        if (s.len == 0 or std.mem.eql(u8, s, ".") or std.mem.eql(u8, s, "..")) return false;
        for (s) |c| {
            if (c < 0x21 or c > 0x7e or std.mem.findScalar(u8, "%?#{}", c) != null) return false;
        }
    }
    return true;
}

const testing = std.testing;
const Context = @import("Context.zig");
const sse = @import("sse.zig");
const Json = @import("dto.zig").Json;
const normalize = @import("path.zig").normalize;

const UsersV1Controller = struct {
    pub const http_routes = route_decls.routes(.{
        .prefix = "/v1/users",
        .methods = .{
            .list = route_decls.get("", .{}),
            .get = route_decls.get("/{id}", .{ .timeout = std.Io.Duration.fromSeconds(5) }),
            .remove = route_decls.delete("/{id}", .{}),
            .events = sse.get("/events", .{ .on_close = .eventsClosed }),
        },
    });

    pub fn list(_: *UsersV1Controller, _: *Context) !void {}
    pub fn get(_: *UsersV1Controller, _: *Context) !Json(struct { id: u64 }) {
        return .{ .value = .{ .id = 1 } };
    }
    pub fn remove(_: *UsersV1Controller, _: *Context) !void {}
    pub fn events(_: *UsersV1Controller, _: *sse.Context) !void {}
    pub fn eventsClosed(_: *UsersV1Controller, _: *sse.Context) void {}
};

const HealthController = struct {
    pub const http_routes = route_decls.routes(.{ .methods = .{
        .root = route_decls.get("", .{}),
        .check = route_decls.get("/health", .{}),
    } });

    pub fn root(_: *HealthController, _: *Context) !void {}
    pub fn check(_: *HealthController, _: *Context) !void {}
};

test "Server.init builds the table and deinit frees it" {
    var users: UsersV1Controller = .{};
    var health: HealthController = .{};
    const backend: Backend = undefined;
    // The prefix of a config: init copies it.
    const config_prefix = try testing.allocator.dupe(u8, "/api");
    var server = init(testing.allocator, .{ .backend = backend, .prefix = config_prefix, .controllers = .{ &users, &health } }) catch |err| {
        testing.allocator.free(config_prefix);
        return err;
    };
    defer server.deinit(testing.io);
    testing.allocator.free(config_prefix);

    const want = [_]struct { std.http.Method, []const u8, []const u8, []const u8 }{
        .{ .GET, "/api/v1/users", "UsersV1Controller", "list" },
        .{ .GET, "/api/v1/users/{id}", "UsersV1Controller", "get" },
        .{ .DELETE, "/api/v1/users/{id}", "UsersV1Controller", "remove" },
        .{ .GET, "/api/v1/users/events", "UsersV1Controller", "events" },
        .{ .GET, "/api", "HealthController", "root" },
        .{ .GET, "/api/health", "HealthController", "check" },
    };
    try testing.expectEqual(want.len, server.routes.len);
    for (want, server.routes) |w, r| {
        try testing.expectEqual(w[0], r.info.method);
        try testing.expectEqualStrings(w[1], r.info.pattern);
        try testing.expectEqualStrings(w[2], r.info.controller);
        try testing.expectEqualStrings(w[3], r.info.handler);
    }
    try testing.expectEqual(@as(*anyopaque, &users), server.routes[1].controller);
    try testing.expectEqual(@as(*anyopaque, &health), server.routes[5].controller);
    try testing.expectEqualStrings("id", server.routes[2].params[0]);
    try testing.expectEqual(route_decls.Timeout{ .after = .fromSeconds(5) }, server.routes[1].timeout);
    try testing.expectEqual(route_decls.Kind.sse, server.routes[3].kind);
    try testing.expectEqualStrings("/api", server.prefix);

    // The router of the server takes its prefix.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const values = try arena.alloc([]const u8, server.router.max_params);
    const m = server.router.match(.DELETE, try normalize(arena, "/api/v1/users/42"), values);
    try testing.expectEqualStrings("remove", server.routes[m.found.route].info.handler);
    try testing.expectEqualStrings("42", m.found.params[0]);
    const root = server.router.match(.GET, try normalize(arena, "/api/"), values);
    try testing.expectEqualStrings("root", server.routes[root.found.route].info.handler);
    try testing.expectEqual(routing.Match.not_found, server.router.match(.GET, try normalize(arena, "/v1/users"), values));
}

test "Server.init: the root without a prefix is /, and a bad prefix is InvalidConfiguration" {
    var health: HealthController = .{};
    const backend: Backend = undefined;
    var server = try init(testing.allocator, .{ .backend = backend, .controllers = .{&health} });
    defer server.deinit(testing.io);
    try testing.expectEqualStrings("/", server.routes[0].info.pattern);
    try testing.expectEqualStrings("/health", server.routes[1].info.pattern);

    for ([_][]const u8{ "api", "/api/", "/", "//api", "/a//b", "/a b", "/a%20b", "/./a", "/a/..", "/{x}", "/a?b", "/a#b", "/caf\xc3\xa9" }) |prefix| {
        testing.expectError(error.InvalidConfiguration, init(testing.allocator, .{ .backend = backend, .prefix = prefix, .controllers = .{&health} })) catch |err| {
            std.debug.print("prefix {s}\n", .{prefix});
            return err;
        };
    }
}

fn initAndDeinit(gpa: std.mem.Allocator) !void {
    var users: UsersV1Controller = .{};
    var health: HealthController = .{};
    const backend: Backend = undefined;
    var server = try init(gpa, .{ .backend = backend, .prefix = "/api", .controllers = .{ &users, &health } });
    server.deinit(testing.io);
}

test "Server.init frees what it took when memory runs out" {
    try testing.checkAllAllocationFailures(testing.allocator, initAndDeinit, .{});
}
