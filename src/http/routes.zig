//! The routes of a controller (design section 5). A controller declares
//! them in `pub const http_routes = http.routes(.{ ... })`: the entries of
//! `.methods` name its methods and are made by `http.get`, `post`, `put`,
//! `patch`, `delete`, `head`, `options` or `http.sse.get`. They are types,
//! so everything here is known at compile time: `http.Server.init` reads
//! the routes from the controller's type and checks them there.
//!
//! ```zig
//! pub const http_routes = http.routes(.{
//!     .prefix = "/v1/todos",
//!     .middleware = .{mw.protected},
//!     .methods = .{
//!         .list = http.get("", .{}),
//!         .get = http.get("/{id}", .{}),
//!         .create = http.post("", .{ .max_body_bytes = 64 << 10 }),
//!         .exportCsv = http.get("/export.csv", .{ .timeout = std.Io.Duration.fromSeconds(300) }),
//!     },
//! });
//! ```
const std = @import("std");

/// What a route serves: a request and its response, or an SSE stream.
pub const Kind = enum { rest, sse };

/// The deadline of a route's requests: the server's `.request_timeout`,
/// none (`.timeout = null`), or the route's own.
pub const Timeout = union(enum) {
    server,
    none,
    after: std.Io.Duration,
};

/// The route a request matched, as `ctx.route()` gives it.
pub const RouteInfo = struct {
    method: std.http.Method,
    /// The server's prefix, the controller's and the route's path, as
    /// declared: "/api/v1/todos/{id}".
    pattern: []const u8,
    /// The controller's type: "TodosV1Controller".
    controller: []const u8,
    /// The controller's method that handles the route: "get".
    handler: []const u8,
};

/// The routes of a controller. `spec` is a struct literal:
/// - `.prefix` (optional): before the path of every route, such as
///   "/v1/todos"; it starts with '/';
/// - `.middleware` (optional): the controller's elements, after the
///   server's;
/// - `.methods`: `.name = http.get(...)` for each `pub fn name` of the
///   controller that serves a route.
pub fn routes(comptime spec: anytype) type {
    const S = @TypeOf(spec);
    if (@typeInfo(S) != .@"struct") @compileError("zefir.http: http.routes takes a struct literal, such as .{ .prefix = \"/v1/todos\", .methods = .{ ... } }");
    expectOptions(S, &.{ "prefix", "middleware", "methods" }, "http.routes");
    const needs_methods = "zefir.http: http.routes needs .methods = .{ .name = http.get(...), ... }";
    if (!@hasField(S, "methods")) @compileError(needs_methods);
    const Methods = @TypeOf(spec.methods);
    if (@typeInfo(Methods) != .@"struct" or @typeInfo(Methods).@"struct".field_names.len == 0) @compileError(needs_methods);
    for (@typeInfo(Methods).@"struct".field_names) |name| {
        const R = @field(spec.methods, name);
        if (@TypeOf(R) != type or !isMarked(R, "zefir_http_route"))
            @compileError("zefir.http: http.routes: .methods." ++ name ++ " must be a route, such as http.get(\"/{id}\", .{})");
    }
    const controller_prefix: []const u8 = if (@hasField(S, "prefix")) spec.prefix else "";
    if (controller_prefix.len > 0 and controller_prefix[0] != '/')
        @compileError("zefir.http: a controller prefix starts with '/' or is empty: \"" ++ controller_prefix ++ "\"");
    return struct {
        pub const zefir_http_routes = {};
        pub const prefix: []const u8 = controller_prefix;
        pub const middleware = if (@hasField(S, "middleware")) spec.middleware else .{};
        pub const methods = spec.methods;
    };
}

/// A GET route; a HEAD request on its path is served by it too, without
/// a body. `opts` may hold `.middleware`, `.max_body_bytes` (a number of
/// bytes, instead of the server's) and `.timeout` (a `std.Io.Duration`
/// instead of the server's `.request_timeout`, or null for no deadline).
pub fn get(comptime path: []const u8, comptime opts: anytype) type {
    return Route(.GET, .rest, path, opts);
}

/// A POST route; `opts` as for `get`.
pub fn post(comptime path: []const u8, comptime opts: anytype) type {
    return Route(.POST, .rest, path, opts);
}

/// A PUT route; `opts` as for `get`.
pub fn put(comptime path: []const u8, comptime opts: anytype) type {
    return Route(.PUT, .rest, path, opts);
}

/// A PATCH route; `opts` as for `get`.
pub fn patch(comptime path: []const u8, comptime opts: anytype) type {
    return Route(.PATCH, .rest, path, opts);
}

/// A DELETE route; `opts` as for `get`.
pub fn delete(comptime path: []const u8, comptime opts: anytype) type {
    return Route(.DELETE, .rest, path, opts);
}

/// A HEAD route of its own, instead of the one a GET route gives its
/// path; `opts` as for `get`.
pub fn head(comptime path: []const u8, comptime opts: anytype) type {
    return Route(.HEAD, .rest, path, opts);
}

/// An OPTIONS route: it answers OPTIONS on its path instead of the
/// server's 204 with `Allow`; `opts` as for `get`.
pub fn options(comptime path: []const u8, comptime opts: anytype) type {
    return Route(.OPTIONS, .rest, path, opts);
}

/// One route, made by the functions above and by `http.sse.get`. A path
/// starts with '/' or is empty (the controller's prefix itself). The
/// options of a route: `.middleware`, `.max_body_bytes` and `.timeout`;
/// of an SSE route: `.middleware`, `.heartbeat` (a `std.Io.Duration`) and
/// `.on_close` (the name of a method of the controller, `.eventsClosed`).
pub fn Route(comptime method: std.http.Method, comptime kind: Kind, comptime path: []const u8, comptime opts: anytype) type {
    const O = @TypeOf(opts);
    const where = switch (kind) {
        .rest => "http." ++ lowerName(method) ++ "(\"" ++ path ++ "\")",
        .sse => "http.sse.get(\"" ++ path ++ "\")",
    };
    if (@typeInfo(O) != .@"struct") @compileError("zefir.http: " ++ where ++ " takes a struct literal of options, such as .{}");
    switch (kind) {
        .rest => expectOptions(O, &.{ "middleware", "max_body_bytes", "timeout" }, where),
        .sse => expectOptions(O, &.{ "middleware", "heartbeat", "on_close" }, where),
    }
    if (path.len > 0 and path[0] != '/') @compileError("zefir.http: a route path starts with '/' or is empty: \"" ++ path ++ "\"");
    if (@hasField(O, "max_body_bytes")) switch (@typeInfo(@TypeOf(opts.max_body_bytes))) {
        .int, .comptime_int => {},
        else => @compileError("zefir.http: " ++ where ++ ": .max_body_bytes is a number of bytes, such as 8 << 20"),
    };
    if (@hasField(O, "timeout")) expectDuration(@TypeOf(opts.timeout), where ++ ": .timeout is a std.Io.Duration, such as std.Io.Duration.fromSeconds(300), or null for no deadline");
    if (@hasField(O, "heartbeat")) expectDuration(@TypeOf(opts.heartbeat), where ++ ": .heartbeat is a std.Io.Duration, such as std.Io.Duration.fromSeconds(15), or null for none");
    if (@hasField(O, "on_close") and @TypeOf(opts.on_close) != @EnumLiteral())
        @compileError("zefir.http: " ++ where ++ ": .on_close names a method of the controller, such as .on_close = .eventsClosed");
    return struct {
        pub const zefir_http_route = {};
        pub const http_method = method;
        pub const route_kind = kind;
        pub const route_path: []const u8 = path;
        pub const middleware = if (@hasField(O, "middleware")) opts.middleware else .{};
        pub const max_body_bytes: ?usize = if (@hasField(O, "max_body_bytes")) opts.max_body_bytes else null;
        pub const timeout: Timeout = if (!@hasField(O, "timeout"))
            .server
        else if (@TypeOf(opts.timeout) == @TypeOf(null)) .none else .{ .after = opts.timeout };
        pub const heartbeat: ?std.Io.Duration = if (@hasField(O, "heartbeat")) opts.heartbeat else null;
        pub const on_close: ?[]const u8 = if (@hasField(O, "on_close")) @tagName(opts.on_close) else null;
    };
}

/// Whether `T` is a container with the declaration `marker`, such as the
/// `zefir_http_route` of a route.
pub fn isMarked(comptime T: type, comptime marker: []const u8) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"enum", .@"union", .@"opaque" => @hasDecl(T, marker),
        else => false,
    };
}

fn expectDuration(comptime T: type, comptime message: []const u8) void {
    if (T != std.Io.Duration and T != @TypeOf(null) and T != ?std.Io.Duration) @compileError("zefir.http: " ++ message);
}

fn lowerName(comptime method: std.http.Method) []const u8 {
    var name: [@tagName(method).len]u8 = undefined;
    _ = std.ascii.lowerString(&name, @tagName(method));
    const final = name;
    return &final;
}

/// Stops the build on a field of `T` that `allowed` does not list.
fn expectOptions(comptime T: type, comptime allowed: []const []const u8, comptime where: []const u8) void {
    var list: []const u8 = "";
    for (allowed, 0..) |name, i| {
        const sep = if (i == 0) "" else if (i == allowed.len - 1) " and " else ", ";
        list = list ++ sep ++ "." ++ name;
    }
    outer: for (@typeInfo(T).@"struct".field_names) |name| {
        for (allowed) |a| if (std.mem.eql(u8, a, name)) continue :outer;
        @compileError("zefir.http: " ++ where ++ ": unknown option ." ++ name ++ "; the options are " ++ list);
    }
}
