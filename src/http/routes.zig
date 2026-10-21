//! The routes of a controller. A controller declares
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
//!
//! A route may declare the input its handler reads and the statuses it
//! answers with; the handler then reads the whole input at once through
//! the route, which is why a route is often named:
//!
//! ```zig
//! const Create = http.post("", .{ .body = dto.CreateTodoRequest, .responses = .{ .created = .{}, .ok = .{} } });
//!
//! const in = try ctx.input(Create); // in.body is a dto.CreateTodoRequest
//! ```
const std = @import("std");
const strings = @import("input/strings.zig");
const json_in = @import("input/json_in.zig");
const plan = @import("plan.zig");

/// What a route serves: a request and its response, or an SSE stream.
pub const Kind = enum { rest, sse };

/// A response that a route declares in `.responses`, besides those of its
/// errors: `.created = .{}`, `.ok = .{ .content_type = "text/csv" }`,
/// `.conflict = .{ .json = T }`.
pub const RouteResponse = struct {
    status: std.http.Status,
    /// The media type of a body that the handler writes itself, such as
    /// "text/csv".
    content_type: ?[]const u8 = null,
    /// The type of a JSON body that the handler writes itself, with
    /// `ctx.response.json`; void for none.
    json: type = void,
};

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
    // A controller declares its routes in one constant, and the compiler
    // counts the work of all of them, and of each `http.get` and the
    // others, against one quota: it is raised here, not by the application.
    @setEvalBranchQuota(route_quota);
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
/// a body. `opts` may hold:
/// - the input of the handler, which `ctx.input` reads at once: `.path`,
///   `.query`, `.headers` and `.cookies` (DTOs of strings, as `ctx.path`
///   and the others read them), and `.body` (a DTO of a JSON body) or
///   `.form` (of an `application/x-www-form-urlencoded` one);
/// - `.responses`: the statuses of a route that answers with something
///   else than one 200 (see `Route`);
/// - `.middleware`, `.max_body_bytes` (a number of bytes, instead of the
///   server's) and `.timeout` (a `std.Io.Duration` above zero instead of
///   the server's `.request_timeout`, or null for no deadline; a
///   `?std.Io.Duration` of the config too).
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
/// options of a route: `.path`, `.query`, `.body`, `.form`, `.headers`,
/// `.cookies`, `.responses`, `.middleware`, `.max_body_bytes` and
/// `.timeout`; of an SSE route: `.path`, `.query`, `.headers`, `.cookies`,
/// `.middleware`, `.heartbeat` (a `std.Io.Duration`) and `.on_close` (the
/// name of a method of the controller, `.eventsClosed`).
///
/// The DTOs of the input are checked here, each for its source, as
/// `ctx.query` and the others check theirs; `.body` and `.form` together
/// stop the build. The route's type declares them as `Path`, `Query`,
/// `Body`, `Form`, `Headers` and `Cookies`, void for what it leaves out,
/// and its statuses as `responses`, in the order of `.responses`.
///
/// `.responses` lists every status the route answers with but those of
/// its errors, which the error handler's `mapError` gives. Without it the
/// route answers 200 with the value of the `http.Json(T)` its handler
/// returns, or 204 for `!void`; with it, only what it lists. Its keys are
/// the names of `std.http.Status`, and each says what the body is:
/// - `.{}`: the value `T` on a 2xx status of a handler that returns
///   `http.Json(T)`; else no body, as of a redirect, `.see_other = .{}`;
/// - `.{ .content_type = "text/csv" }`: a body of that type, which the
///   handler writes itself;
/// - `.{ .json = T }`: a JSON body of type `T`, which the handler writes
///   itself with `ctx.response.json`.
pub fn Route(comptime method: std.http.Method, comptime kind: Kind, comptime path: []const u8, comptime opts: anytype) type {
    @setEvalBranchQuota(route_quota);
    const O = @TypeOf(opts);
    const where = switch (kind) {
        .rest => "http." ++ lowerName(method) ++ "(\"" ++ path ++ "\")",
        .sse => "http.sse.get(\"" ++ path ++ "\")",
    };
    if (@typeInfo(O) != .@"struct") @compileError("zefir.http: " ++ where ++ " takes a struct literal of options, such as .{}");
    switch (kind) {
        .rest => expectOptions(O, &.{ "path", "query", "body", "form", "headers", "cookies", "responses", "middleware", "max_body_bytes", "timeout" }, where),
        .sse => expectOptions(O, &.{ "path", "query", "headers", "cookies", "middleware", "heartbeat", "on_close" }, where),
    }
    if (path.len > 0 and path[0] != '/') @compileError("zefir.http: a route path starts with '/' or is empty: \"" ++ path ++ "\"");
    if (@hasField(O, "max_body_bytes")) switch (@typeInfo(@TypeOf(opts.max_body_bytes))) {
        .int, .comptime_int => {},
        else => @compileError("zefir.http: " ++ where ++ ": .max_body_bytes is a number of bytes, such as 8 << 20"),
    };
    const timeout_form = where ++ ": .timeout is a std.Io.Duration above zero, such as std.Io.Duration.fromSeconds(300), or null for no deadline";
    const heartbeat_form = where ++ ": .heartbeat is a std.Io.Duration above zero, such as std.Io.Duration.fromSeconds(15), or null for none";
    if (@hasField(O, "timeout")) expectDuration(@TypeOf(opts.timeout), timeout_form);
    if (@hasField(O, "heartbeat")) expectDuration(@TypeOf(opts.heartbeat), heartbeat_form);
    if (@hasField(O, "on_close") and @TypeOf(opts.on_close) != @EnumLiteral())
        @compileError("zefir.http: " ++ where ++ ": .on_close names a method of the controller, such as .on_close = .eventsClosed");
    const declared = declarationsOf(opts, where);
    return struct {
        pub const zefir_http_route = {};
        pub const http_method = method;
        pub const route_kind = kind;
        pub const route_path: []const u8 = path;
        pub const middleware = if (@hasField(O, "middleware")) opts.middleware else .{};
        pub const max_body_bytes: ?usize = if (@hasField(O, "max_body_bytes")) opts.max_body_bytes else null;
        pub const timeout: Timeout = if (!@hasField(O, "timeout"))
            .server
        else if (positive(opts.timeout, timeout_form)) |budget| .{ .after = budget } else .none;
        pub const heartbeat: ?std.Io.Duration = if (@hasField(O, "heartbeat")) positive(opts.heartbeat, heartbeat_form) else null;
        pub const on_close: ?[]const u8 = if (@hasField(O, "on_close")) @tagName(opts.on_close) else null;
        /// The DTOs of the input, void for a source the route leaves out.
        pub const Path: type = declared.Path;
        pub const Query: type = declared.Query;
        pub const Body: type = declared.Body;
        pub const Form: type = declared.Form;
        pub const Headers: type = declared.Headers;
        pub const Cookies: type = declared.Cookies;
        /// As `.responses` lists them; empty without it.
        pub const responses: []const RouteResponse = declared.responses;
    };
}

/// The eval branch quota of a controller's declaration of its routes: a few
/// hundred branches a route, so some hundreds of routes a controller.
const route_quota = 200_000;

/// The input that the route `R` declares, as `ctx.input(R)` gives it: a
/// field for each source it declares, of its DTO, in the order the sources
/// are read: `path`, `query`, `headers`, `cookies`, then `body` or `form`.
pub fn Input(comptime R: type) type {
    comptime {
        expectRoute(R, "http.Input");
        const all_names = [_][:0]const u8{ "path", "query", "headers", "cookies", "body", "form" };
        const all_types = [_]type{ R.Path, R.Query, R.Headers, R.Cookies, R.Body, R.Form };
        var names: []const [:0]const u8 = &.{};
        var types: []const type = &.{};
        for (all_names, all_types) |name, T| {
            if (T == void) continue;
            names = names ++ [_][:0]const u8{name};
            types = types ++ [_]type{T};
        }
        const attrs: [names.len]std.lang.Type.Struct.FieldAttributes = @splat(.{});
        return @Struct(.auto, null, names, types[0..names.len], &attrs);
    }
}

/// Stops the build when `R` is not a route made by `http.get` and the
/// others; `call` names what took it.
pub fn expectRoute(comptime R: type, comptime call: []const u8) void {
    if (!isMarked(R, "zefir_http_route"))
        @compileError("zefir.http: " ++ call ++ " takes a route, such as " ++ call ++ "(Get) with const Get = http.get(\"/{id}\", .{ .path = dto.TodoIdPath }); got " ++ plan.typeName(R));
}

/// What a route declares of its input and its statuses.
const Declarations = struct {
    Path: type = void,
    Query: type = void,
    Body: type = void,
    Form: type = void,
    Headers: type = void,
    Cookies: type = void,
    responses: []const RouteResponse = &.{},
};

/// The input and the statuses of the options `opts`, each DTO checked for
/// its source.
fn declarationsOf(comptime opts: anytype, comptime where: []const u8) Declarations {
    const d: Declarations = .{
        .Path = dtoOf(opts, "path", "dto.TodoIdPath", where),
        .Query = dtoOf(opts, "query", "dto.ListTodosQuery", where),
        .Body = dtoOf(opts, "body", "dto.CreateTodoRequest", where),
        .Form = dtoOf(opts, "form", "dto.LoginForm", where),
        .Headers = dtoOf(opts, "headers", "dto.CreateTodoHeaders", where),
        .Cookies = dtoOf(opts, "cookies", "dto.SessionCookies", where),
        .responses = if (@hasField(@TypeOf(opts), "responses")) responsesOf(opts.responses, where) else &.{},
    };
    if (d.Body != void and d.Form != void) @compileError("zefir.http: " ++ where ++ ": .body and .form together; a body is JSON or a form");
    if (d.Path != void) strings.check(d.Path, .path);
    if (d.Query != void) strings.check(d.Query, .query);
    if (d.Headers != void) strings.check(d.Headers, .headers);
    if (d.Cookies != void) strings.check(d.Cookies, .cookies);
    if (d.Form != void) strings.check(d.Form, .form);
    if (d.Body != void) json_in.check(d.Body);
    return d;
}

/// The DTO of the option `name`, void without it; `example` shows one in
/// the message of a value that is not a type.
fn dtoOf(comptime opts: anytype, comptime name: []const u8, comptime example: []const u8, comptime where: []const u8) type {
    if (!@hasField(@TypeOf(opts), name)) return void;
    const T = @field(opts, name);
    if (@TypeOf(T) != type) @compileError("zefir.http: " ++ where ++ ": ." ++ name ++ " is the type of a DTO, such as ." ++ name ++ " = " ++ example);
    return T;
}

/// The statuses of `.responses`, in their order.
fn responsesOf(comptime list: anytype, comptime where: []const u8) []const RouteResponse {
    const L = @TypeOf(list);
    if (@typeInfo(L) != .@"struct")
        @compileError("zefir.http: " ++ where ++ ": .responses is a struct literal of statuses, such as .responses = .{ .created = .{}, .ok = .{} }");
    var out: []const RouteResponse = &.{};
    for (@typeInfo(L).@"struct".field_names) |key| {
        if (!@hasField(std.http.Status, key))
            @compileError("zefir.http: " ++ where ++ ": .responses." ++ key ++ ": the keys of .responses are names of std.http.Status, such as .ok, .created or .see_other");
        out = out ++ [_]RouteResponse{entryOf(@field(std.http.Status, key), @field(list, key), where)};
    }
    return out;
}

/// The entry of `status` in `.responses`: `.{}`, `.{ .content_type = ... }`
/// or `.{ .json = T }`.
fn entryOf(comptime status: std.http.Status, comptime entry: anytype, comptime where: []const u8) RouteResponse {
    const E = @TypeOf(entry);
    const form = "zefir.http: " ++ where ++ ": .responses." ++ @tagName(status) ++ " must be .{}, .{ .content_type = \"text/csv\" } or .{ .json = T }";
    if (@typeInfo(E) != .@"struct") @compileError(form);
    var out: RouteResponse = .{ .status = status };
    for (@typeInfo(E).@"struct".field_names) |name| {
        const value = @field(entry, name);
        if (std.mem.eql(u8, name, "content_type") and isText(@TypeOf(value))) {
            out.content_type = value;
        } else if (std.mem.eql(u8, name, "json") and @TypeOf(value) == type) {
            out.json = value;
        } else @compileError(form);
    }
    if (out.content_type != null and out.json != void) @compileError(form);
    return out;
}

/// Whether a value of type `T` is a string: a slice of bytes or a pointer
/// to an array of them, as a literal is.
fn isText(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info != .pointer) return false;
    return switch (info.pointer.size) {
        .slice => info.pointer.child == u8,
        .one => @typeInfo(info.pointer.child) == .array and @typeInfo(info.pointer.child).array.child == u8,
        else => false,
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

/// A duration of the options, null for none; one of zero or below stops the
/// build with `message`, since a route's options are known at compile time.
fn positive(comptime value: anytype, comptime message: []const u8) ?std.Io.Duration {
    const duration: ?std.Io.Duration = value;
    if (duration) |d| if (d.nanoseconds <= 0) @compileError("zefir.http: " ++ message);
    return duration;
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

const testing = std.testing;

// The DTOs of the tests' routes: application code.
const TodoIdPath = struct { id: u64 };
const ListQuery = struct { page: u32 = 1 };
const CreateTodo = struct { title: []const u8 };
const LoginForm = struct { user: []const u8 };
const KeyHeaders = struct { idempotency_key: ?[]const u8 = null };
const SessionCookies = struct { session: ?[]const u8 = null };
const Conflict = struct { code: []const u8 };

test "routes: a route declares its input and statuses; what it leaves out is void" {
    const Plain = get("/{id}", .{});
    inline for (.{ Plain.Path, Plain.Query, Plain.Body, Plain.Form, Plain.Headers, Plain.Cookies }) |T| try testing.expect(T == void);
    try testing.expectEqual(0, Plain.responses.len);

    const Create = post("/{id}", .{
        .path = TodoIdPath,
        .query = ListQuery,
        .body = CreateTodo,
        .headers = KeyHeaders,
        .cookies = SessionCookies,
        .responses = .{ .created = .{}, .ok = .{}, .conflict = .{ .json = Conflict }, .see_other = .{} },
        .max_body_bytes = 64 << 10,
        .timeout = null,
    });
    try testing.expect(Create.Path == TodoIdPath);
    try testing.expect(Create.Query == ListQuery);
    try testing.expect(Create.Body == CreateTodo);
    try testing.expect(Create.Form == void);
    try testing.expect(Create.Headers == KeyHeaders);
    try testing.expect(Create.Cookies == SessionCookies);
    // The statuses as declared, in their order.
    try testing.expectEqual(4, Create.responses.len);
    const want = [_]std.http.Status{ .created, .ok, .conflict, .see_other };
    inline for (want, Create.responses) |status, r| try testing.expectEqual(status, r.status);
    try testing.expect(Create.responses[2].json == Conflict);
    try testing.expect(Create.responses[0].json == void and Create.responses[0].content_type == null);
    // The other options are kept as they were.
    try testing.expectEqual(64 << 10, Create.max_body_bytes.?);
    try testing.expectEqual(Timeout.none, Create.timeout);
    try testing.expectEqualStrings("/{id}", Create.route_path);

    // A form body; a body of another type, which the handler writes.
    const Login = post("/login", .{ .form = LoginForm, .responses = .{ .see_other = .{} } });
    try testing.expect(Login.Form == LoginForm and Login.Body == void);
    try testing.expectEqual(std.http.Status.see_other, Login.responses[0].status);
    const Export = get("/export.csv", .{ .responses = .{ .ok = .{ .content_type = "text/csv" } } });
    try testing.expectEqualStrings("text/csv", Export.responses[0].content_type.?);
    try testing.expect(Export.responses[0].json == void);
}

test "routes: an SSE route declares its path, query, headers and cookies" {
    const Events = Route(.GET, .sse, "/events/{id}", .{
        .path = TodoIdPath,
        .query = ListQuery,
        .headers = KeyHeaders,
        .cookies = SessionCookies,
        .heartbeat = std.Io.Duration.fromSeconds(15),
    });
    try testing.expect(Events.Path == TodoIdPath and Events.Query == ListQuery);
    try testing.expect(Events.Headers == KeyHeaders and Events.Cookies == SessionCookies);
    try testing.expect(Events.Body == void and Events.Form == void);
    try testing.expectEqual(0, Events.responses.len);
    try testing.expectEqual(std.Io.Duration.fromSeconds(15), Events.heartbeat.?);
}
