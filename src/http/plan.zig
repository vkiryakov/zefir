//! The compile-time plan of a server (design sections 4 and 5):
//! `of(@TypeOf(options))` reads the options of `Server.init` and the
//! routes of its controllers, builds the router's trie and stops the build
//! on a mistake, with a message that names the place and what to write:
//! - an unknown option, or no `.backend` or `.controllers`;
//! - a controller that is not a pointer to a mutable instance, has no
//!   `pub const http_routes`, or whose `http_routes` is not
//!   `http.routes(...)`;
//! - a route without its handler, a handler of another form, an
//!   `.on_close` that names no method of its form;
//! - a pattern that does not parse, two routes of one method on one shape
//!   of path (router.zig);
//! - an element of a `.middleware` list of no kind the server takes, or a
//!   phase of another form (middleware.zig);
//! - an `.error_handler` that is not a pointer to a mutable error handler
//!   with `pub fn mapError(err: anyerror) http.ErrorResponse(Body)` and,
//!   optionally, a `handle` of its form;
//! - the strict error check (strict.zig), unless `.strict_errors = false`.
//!
//! The chain of each route is built here: the server's middleware, then
//! the controller's, then the method's, sets unfolded; nothing is looked up
//! while a request runs.
const std = @import("std");
const v = @import("validator");
const routes = @import("routes.zig");
const router = @import("router.zig");
const Context = @import("Context.zig");
const sse = @import("sse.zig");
const errors = @import("errors.zig");
const strict = @import("strict.zig");
const mw = @import("middleware.zig");

/// One route of the server, at compile time.
pub const RoutePlan = struct {
    method: std.http.Method,
    kind: routes.Kind,
    /// The controller's prefix and the route's path, as declared:
    /// "/v1/todos/{id}"; "" for the root. The server's prefix joins them at
    /// run time: it may come from the config.
    pattern: []const u8,
    /// The names of the pattern's parameters, in order.
    params: []const []const u8,
    /// The controller: its place in `.controllers`, its type and its name.
    controller_index: usize,
    Controller: type,
    controller_name: []const u8,
    /// The controller's method that handles the route.
    handler: []const u8,
    /// The route as `http.get` and the others made it, with its
    /// `.middleware`.
    Route: type,
    max_body_bytes: ?usize,
    timeout: routes.Timeout,
    heartbeat: ?std.Io.Duration,
    on_close: ?[]const u8,
    /// The route's own middleware, after the server's: the controller's
    /// elements, then the method's, each list in its order, sets unfolded.
    chain: []const mw.Elem,
    /// How many elements of `chain` are the controller's.
    controller_elems: usize,
};

pub const Plan = struct {
    /// In the order of `.controllers`, each in the order of its `.methods`.
    routes: []const RoutePlan,
    /// The router's trie; its routes are indices into `routes`.
    nodes: []const router.Node,
    /// The most parameters a route has.
    max_params: usize,
    /// The type of `.error_handler`'s object, else `errors.DefaultErrors`.
    Handler: type,
    /// The server's middleware, sets unfolded: every request runs it,
    /// before its route is applied.
    global: []const mw.Elem,
};

const known_options = [_][]const u8{
    "backend",       "prefix",          "controllers",    "middleware",     "error_handler",    "static",
    "strict_errors", "unknown_fields",  "json",           "max_body_bytes", "max_query_params", "max_in_flight",
    "max_streams",   "request_timeout", "shutdown_grace", "finish_timeout", "trusted_proxies",
};

pub fn of(comptime O: type) Plan {
    var quota: u32 = 100_000;
    @setEvalBranchQuota(quota);
    if (@typeInfo(O) != .@"struct") @compileError("zefir.http: Server.init takes a struct literal of options, got " ++ @typeName(O));
    for (@typeInfo(O).@"struct".field_names) |name| {
        if (!contains(&known_options, name)) @compileError("zefir.http: Server.init: unknown option ." ++ name);
    }
    if (!@hasField(O, "backend")) @compileError("zefir.http: Server.init needs .backend, such as native.backend()");
    const controllers_form = "zefir.http: Server.init .controllers is a tuple of pointers to controllers, at least one: .{ &todos_v1, &health }";
    if (!@hasField(O, "controllers")) @compileError(controllers_form);
    const cinfo = @typeInfo(@FieldType(O, "controllers"));
    if (cinfo != .@"struct" or !cinfo.@"struct".is_tuple or cinfo.@"struct".field_names.len == 0) @compileError(controllers_form);

    const Global = if (@hasField(O, "middleware")) @FieldType(O, "middleware") else @TypeOf(.{});
    quota += elem_quota * elemsIn(Global);
    @setEvalBranchQuota(quota);
    const global = mw.unfold(Global, .{ .level = .global }, &.{});

    var table: []const RoutePlan = &.{};
    var specs: []const router.Spec = &.{};
    var max_params: usize = 0;
    for (cinfo.@"struct".field_types, 0..) |Ptr, ci| {
        const C = controllerOf(Ptr, ci);
        const cname = shortName(@typeName(C));
        // A declaration without pub in the application's file is not
        // visible here: the same message covers it.
        if (!@hasDecl(C, "http_routes")) @compileError("zefir.http: " ++ cname ++ " has no pub const http_routes = http.routes(.{ ... })");
        const R = C.http_routes;
        if (@TypeOf(R) != type or !routes.isMarked(R, "zefir_http_routes")) @compileError("zefir.http: " ++ cname ++ ".http_routes must be http.routes(.{ ... })");
        quota += elem_quota * elemsIn(@TypeOf(R.middleware));
        @setEvalBranchQuota(quota);
        const controller_chain = mw.unfold(@TypeOf(R.middleware), .{ .level = .controller, .Controller = C }, &.{});
        for (@typeInfo(@TypeOf(R.methods)).@"struct".field_names) |name| {
            const Route = @field(R.methods, name);
            const where = cname ++ "." ++ name;
            const pattern = R.prefix ++ Route.route_path;
            quota += 20_000 + 500 * @as(u32, @intCast(pattern.len)) + elem_quota * elemsIn(@TypeOf(Route.middleware)) +
                chain_quota * @as(u32, @intCast(controller_chain.len));
            @setEvalBranchQuota(quota);
            checkHandler(C, name, Route.route_kind, where);
            if (Route.on_close) |on_close| checkOnClose(C, on_close, where);
            const segments = router.parse(pattern, where);
            const params = router.paramNames(segments);
            max_params = @max(max_params, params.len);
            const method_chain = mw.unfold(@TypeOf(Route.middleware), .{ .level = .method, .Controller = C, .method = name }, &.{});
            table = table ++ [_]RoutePlan{.{
                .method = Route.http_method,
                .kind = Route.route_kind,
                .pattern = pattern,
                .params = params,
                .controller_index = ci,
                .Controller = C,
                .controller_name = cname,
                .handler = name,
                .Route = Route,
                .max_body_bytes = Route.max_body_bytes,
                .timeout = Route.timeout,
                .heartbeat = Route.heartbeat,
                .on_close = Route.on_close,
                .chain = controller_chain ++ method_chain,
                .controller_elems = controller_chain.len,
            }};
            specs = specs ++ [_]router.Spec{.{
                .method = Route.http_method,
                .kind = Route.route_kind,
                .segments = segments,
                .name = where,
                .pattern = pattern,
            }};
        }
    }
    const nodes = router.build(specs);
    const Handler = errorHandlerOf(O);
    if (strictOf(O)) strict.check(Handler, shortName(@typeName(Handler)), strictEntries(table, global));
    return .{ .routes = table, .nodes = nodes, .max_params = max_params, .Handler = Handler, .global = global };
}

/// The quota of describing one element of a `.middleware` list, and of
/// taking one element of a controller's chain into a route's.
const elem_quota = 6_000;
const chain_quota = 200;

/// How many elements a `.middleware` tuple holds, sets counted through.
fn elemsIn(comptime List: type) u32 {
    const info = @typeInfo(List);
    if (info != .@"struct" or !info.@"struct".is_tuple) return 1;
    var count: u32 = 1;
    for (info.@"struct".field_types) |Item| count += elemsIn(Item);
    return count;
}

/// The error handler of `O`: the type of the object `.error_handler`
/// points to, checked, or the default one.
fn errorHandlerOf(comptime O: type) type {
    if (!@hasField(O, "error_handler")) return errors.DefaultErrors;
    const P = @FieldType(O, "error_handler");
    const info = @typeInfo(P);
    const at = "zefir.http: Server.init .error_handler is ";
    if (info != .pointer or info.pointer.size != .one or @typeInfo(info.pointer.child) != .@"struct")
        @compileError(at ++ typeName(P) ++ "; pass a pointer to the error handler, e.g. &app_errors");
    if (info.pointer.attrs.@"const")
        @compileError(at ++ typeName(P) ++ "; the error handler must be mutable, declared with var");
    const H = info.pointer.child;
    checkErrorHandler(H);
    return H;
}

/// `pub fn mapError(err: anyerror) http.ErrorResponse(Body)`, and an
/// optional `pub fn handle(self: *H, ctx: *http.Context, err: anyerror,
/// res: *http.ErrorResponse(Body)) !http.ErrorAction`.
fn checkErrorHandler(comptime H: type) void {
    const name = shortName(@typeName(H));
    const map_form = "pub fn mapError(err: anyerror) http.ErrorResponse(Body)";
    if (!@hasDecl(H, "mapError")) @compileError("zefir.http: the error handler " ++ name ++ " has no " ++ map_form);
    const M = @TypeOf(H.mapError);
    const bad_map = "zefir.http: " ++ name ++ ".mapError is " ++ fnForm(M) ++ "; write " ++ map_form ++
        " (no ctx: the strict error check calls it at compile time)";
    if (@typeInfo(M) != .@"fn") @compileError(bad_map);
    const minfo = @typeInfo(M).@"fn";
    if (minfo.is_generic or minfo.param_types.len != 1 or minfo.param_types[0].? != anyerror) @compileError(bad_map);
    const Res = minfo.return_type.?;
    if (!routes.isMarked(Res, "zefir_http_error_response")) @compileError(bad_map);
    if (!@hasDecl(H, "handle")) return;
    const handle_form = "pub fn handle(self: *" ++ name ++ ", ctx: *http.Context, err: anyerror, res: *http.ErrorResponse(" ++
        typeName(Res.Body) ++ ")) !http.ErrorAction";
    const F = @TypeOf(H.handle);
    const bad = "zefir.http: " ++ name ++ ".handle is " ++ fnForm(F) ++ "; write " ++ handle_form;
    if (@typeInfo(F) != .@"fn") @compileError(bad);
    const info = @typeInfo(F).@"fn";
    if (info.is_generic or info.param_types.len != 4 or info.param_types[0].? != *H or info.param_types[1].? != *Context or
        info.param_types[2].? != anyerror or info.param_types[3].? != *Res) @compileError(bad);
    if (payloadOf(info.return_type.?) != errors.ErrorAction) @compileError(bad);
}

/// `.strict_errors`, known at compile time; true without it.
fn strictOf(comptime O: type) bool {
    const info = @typeInfo(O).@"struct";
    for (info.field_names, info.field_types, info.field_attrs) |name, T, attrs| {
        if (!std.mem.eql(u8, name, "strict_errors")) continue;
        if (T != bool) @compileError("zefir.http: Server.init .strict_errors is true or false, got " ++ typeName(T));
        if (!attrs.@"comptime") @compileError("zefir.http: Server.init .strict_errors must be known at compile time: true or false");
        return attrs.defaultValue(bool).?;
    }
    return true;
}

/// The places whose errors the strict error check reads: the handler of
/// every route, the transforms of the JSON value it answers with, which
/// run before the response goes out, and the `run` of each element of its
/// chain. The errors of `onResponse` and `onFinish` are only logged. Each
/// `run` is read once, under the first route that has it: the server's
/// elements under the first route, a controller's under its first.
fn strictEntries(comptime table: []const RoutePlan, comptime global: []const mw.Elem) []const strict.Entry {
    var out: []const strict.Entry = &.{};
    var visited: []const type = &.{};
    for (table, 0..) |r, ri| {
        const where = r.controller_name ++ "." ++ r.handler;
        const R = @typeInfo(@TypeOf(@field(r.Controller, r.handler))).@"fn".return_type.?;
        const E = if (@typeInfo(R) == .error_union) @typeInfo(R).error_union.error_set else error{};
        out = out ++ [_]strict.Entry{.{ .where = where, .Errors = E }};
        const Payload = payloadOf(R);
        if (Payload != void)
            out = out ++ [_]strict.Entry{.{ .where = where ++ " (writing its response)", .Errors = v.TransformError(Payload.Value) }};
        const first_of_controller = ri == 0 or table[ri - 1].controller_index != r.controller_index;
        const server_elems: []const mw.Elem = if (ri == 0) global else &.{};
        const own = if (first_of_controller) r.chain else r.chain[r.controller_elems..];
        for (server_elems ++ own) |e| {
            if (!@hasDecl(e.Impl, "run") or containsType(visited, e.Impl)) continue;
            visited = visited ++ [_]type{e.Impl};
            out = out ++ [_]strict.Entry{.{ .where = e.name ++ ".run (middleware of " ++ where ++ ")", .Errors = mw.ErrorSetOf(@TypeOf(e.Impl.run)) }};
        }
    }
    return out;
}

fn containsType(comptime list: []const type, comptime T: type) bool {
    for (list) |item| {
        if (item == T) return true;
    }
    return false;
}

/// The controller of the element `Ptr` of `.controllers`: a pointer to a
/// mutable instance.
fn controllerOf(comptime Ptr: type, comptime index: usize) type {
    const at = std.fmt.comptimePrint("zefir.http: Server.init .controllers[{d}] is ", .{index});
    const info = @typeInfo(Ptr);
    if (info != .pointer or info.pointer.size != .one or @typeInfo(info.pointer.child) != .@"struct")
        @compileError(at ++ typeName(Ptr) ++ "; pass a pointer to the controller, e.g. &controller");
    if (info.pointer.attrs.@"const")
        @compileError(at ++ typeName(Ptr) ++ "; the controller must be mutable, declared with var");
    return info.pointer.child;
}

fn checkHandler(comptime C: type, comptime name: []const u8, comptime kind: routes.Kind, comptime where: []const u8) void {
    const cname = shortName(@typeName(C));
    const form = switch (kind) {
        .rest => "pub fn " ++ name ++ "(self: *" ++ cname ++ ", ctx: *http.Context) !http.Json(T), or !void for a response without a JSON value",
        .sse => "pub fn " ++ name ++ "(self: *" ++ cname ++ ", ctx: *http.sse.Context) !void",
    };
    if (!@hasDecl(C, name)) @compileError("zefir.http: " ++ where ++ ": the route has no handler; write " ++ form);
    const F = @TypeOf(@field(C, name));
    const bad = "zefir.http: " ++ where ++ " is " ++ fnForm(F) ++ "; write " ++ form;
    if (@typeInfo(F) != .@"fn") @compileError(bad);
    const info = @typeInfo(F).@"fn";
    if (info.is_generic or info.param_types.len != 2 or info.param_types[0].? != *C) @compileError(bad);
    const Ctx = switch (kind) {
        .rest => *Context,
        .sse => *sse.Context,
    };
    if (info.param_types[1].? != Ctx) @compileError(bad);
    const Payload = payloadOf(info.return_type.?);
    const ok = switch (kind) {
        .rest => Payload == void or routes.isMarked(Payload, "zefir_http_json"),
        .sse => Payload == void,
    };
    if (!ok) @compileError(bad);
}

fn checkOnClose(comptime C: type, comptime name: []const u8, comptime where: []const u8) void {
    const cname = shortName(@typeName(C));
    const form = "pub fn " ++ name ++ "(self: *" ++ cname ++ ", ctx: *http.sse.Context) void";
    const at = "zefir.http: " ++ where ++ ": .on_close = ." ++ name;
    if (!@hasDecl(C, name)) @compileError(at ++ " names no " ++ form);
    const F = @TypeOf(@field(C, name));
    if (F != fn (*C, *sse.Context) void) @compileError(at ++ " is " ++ fnForm(F) ++ "; write " ++ form);
}

fn payloadOf(comptime R: type) type {
    return if (@typeInfo(R) == .error_union) @typeInfo(R).error_union.payload else R;
}

fn contains(comptime list: []const []const u8, comptime name: []const u8) bool {
    for (list) |item| {
        if (std.mem.eql(u8, item, name)) return true;
    }
    return false;
}

/// A type as messages print it: `*const UsersV1Controller`, without the
/// file that declares it; the types of zefir-http as the application names
/// them, `http.ErrorResponse(ApiError)` with its body.
pub fn typeName(comptime T: type) []const u8 {
    if (T == Context) return "http.Context";
    if (T == sse.Context) return "http.sse.Context";
    if (T == errors.Problem) return "http.Problem";
    if (T == errors.ErrorAction) return "http.ErrorAction";
    if (T == mw.MiddlewareResult) return "http.MiddlewareResult";
    if (T == mw.Outcome) return "http.Outcome";
    if (routes.isMarked(T, "zefir_http_error_response")) return "http.ErrorResponse(" ++ typeName(T.Body) ++ ")";
    if (routes.isMarked(T, "zefir_http_json")) return "http.Json(" ++ typeName(T.Value) ++ ")";
    const info = @typeInfo(T);
    if (info == .pointer and info.pointer.size == .one)
        return "*" ++ (if (info.pointer.attrs.@"const") "const " else "") ++ typeName(info.pointer.child);
    return shortName(@typeName(T));
}

/// The form of a function type, for messages: `fn (*C, *const Context) !void`.
pub fn fnForm(comptime F: type) []const u8 {
    if (@typeInfo(F) != .@"fn") return typeName(F);
    const info = @typeInfo(F).@"fn";
    var text: []const u8 = "fn (";
    for (info.param_types, 0..) |P, i| text = text ++ (if (i == 0) "" else ", ") ++ (if (P) |T| typeName(T) else "anytype");
    const R = info.return_type orelse return text ++ ") anytype";
    const ret = if (@typeInfo(R) == .error_union) "!" ++ typeName(@typeInfo(R).error_union.payload) else typeName(R);
    return text ++ ") " ++ ret;
}

/// The last part of a type's name, outside parentheses:
/// "todos.TodosV1Controller" is "TodosV1Controller".
pub fn shortName(comptime full: []const u8) []const u8 {
    var depth: usize = 0;
    var start: usize = 0;
    for (full, 0..) |c, i| switch (c) {
        '(' => depth += 1,
        ')' => depth -= 1,
        '.' => if (depth == 0) {
            start = i + 1;
        },
        else => {},
    };
    return full[start..];
}

const testing = std.testing;
const Backend = @import("Backend.zig");
const Json = @import("dto.zig").Json;

/// A value of the tests' types.
const Todo = struct { id: u64 };

// Application code of the tests below: zefir-http ships no middleware.
const Audit = struct {
    pub fn onFinish(_: *Audit, _: *Context, _: mw.Outcome) !void {}
};
const PlanLookup = struct {
    pub fn run(_: *PlanLookup, _: *Context) !mw.MiddlewareResult {
        return .next;
    }
};
var audit_object: Audit = .{};
var plans_object: PlanLookup = .{};

const UsersV1Controller = struct {
    calls: u32 = 0,
    audit: *Audit = &audit_object,
    plans: *PlanLookup = &plans_object,

    pub const http_routes = routes.routes(.{
        .prefix = "/v1/users",
        .middleware = .{.audit},
        .methods = .{
            .list = routes.get("", .{}),
            .get = routes.get("/{id}", .{ .timeout = std.Io.Duration.fromSeconds(5) }),
            .create = routes.post("/", .{ .max_body_bytes = 64 << 10, .timeout = null, .middleware = .{.plans} }),
            .files = routes.get("/{id}/files/{*path}", .{}),
            .events = sse.get("/events", .{ .heartbeat = std.Io.Duration.fromSeconds(15), .on_close = .eventsClosed }),
        },
    });

    pub fn list(_: *UsersV1Controller, _: *Context) !void {}
    pub fn get(_: *UsersV1Controller, _: *Context) !Json(struct { id: u64 }) {
        return .{ .value = .{ .id = 1 } };
    }
    pub fn create(_: *UsersV1Controller, _: *Context) error{Conflict}!Json(struct { id: u64 }) {
        return .{ .value = .{ .id = 2 }, .status = 201 };
    }
    pub fn files(_: *UsersV1Controller, _: *Context) void {}
    pub fn events(_: *UsersV1Controller, _: *sse.Context) !void {}
    pub fn eventsClosed(_: *UsersV1Controller, _: *sse.Context) void {}
};

const HealthController = struct {
    pub const http_routes = routes.routes(.{ .methods = .{ .check = routes.get("/health", .{}) } });

    pub fn check(_: *HealthController, _: *Context) !void {}
};

test "routes: patterns are the controller prefix plus the path; options are kept" {
    var users: UsersV1Controller = .{};
    var health: HealthController = .{};
    const backend: Backend = undefined;
    // UsersV1Controller.create returns an error of its own, which only an
    // error handler maps.
    const p = comptime of(@TypeOf(.{ .backend = backend, .prefix = "/api", .controllers = .{ &users, &health }, .strict_errors = false }));
    try testing.expectEqual(6, p.routes.len);
    try testing.expectEqual(2, p.max_params);

    const want = [_]struct { std.http.Method, routes.Kind, []const u8, []const u8, usize }{
        .{ .GET, .rest, "/v1/users", "list", 0 },
        .{ .GET, .rest, "/v1/users/{id}", "get", 0 },
        .{ .POST, .rest, "/v1/users/", "create", 0 },
        .{ .GET, .rest, "/v1/users/{id}/files/{*path}", "files", 0 },
        .{ .GET, .sse, "/v1/users/events", "events", 0 },
        .{ .GET, .rest, "/health", "check", 1 },
    };
    inline for (want, p.routes) |w, r| {
        try testing.expectEqual(w[0], r.method);
        try testing.expectEqual(w[1], r.kind);
        try testing.expectEqualStrings(w[2], r.pattern);
        try testing.expectEqualStrings(w[3], r.handler);
        try testing.expectEqual(w[4], r.controller_index);
    }
    try testing.expectEqualStrings("UsersV1Controller", p.routes[0].controller_name);
    try testing.expectEqualStrings("HealthController", p.routes[5].controller_name);
    try testing.expect(p.routes[0].Controller == UsersV1Controller);

    // The options of each route, and the defaults where it has none.
    try testing.expectEqual(routes.Timeout.server, p.routes[0].timeout);
    try testing.expectEqual(null, p.routes[0].max_body_bytes);
    try testing.expectEqual(routes.Timeout{ .after = .fromSeconds(5) }, p.routes[1].timeout);
    try testing.expectEqual(64 << 10, p.routes[2].max_body_bytes.?);
    try testing.expectEqual(routes.Timeout.none, p.routes[2].timeout);
    try testing.expectEqual(std.Io.Duration.fromSeconds(15), p.routes[4].heartbeat.?);
    try testing.expectEqualStrings("eventsClosed", p.routes[4].on_close.?);
    try testing.expectEqual(null, p.routes[1].heartbeat);
    try testing.expectEqual(null, p.routes[1].on_close);
    try testing.expect(p.routes[2].Route.middleware[0] == .plans);
    try testing.expect(p.routes[2].Controller.http_routes.middleware[0] == .audit);
    try testing.expectEqual(0, p.routes[0].Route.middleware.len);
    // The chains: the controller's element, then the method's.
    try testing.expectEqual(0, p.global.len);
    try testing.expectEqual(1, p.routes[0].chain.len);
    try testing.expectEqualStrings(".audit (Audit)", p.routes[0].chain[0].name);
    try testing.expectEqual(2, p.routes[2].chain.len);
    try testing.expectEqual(1, p.routes[2].controller_elems);
    try testing.expectEqualStrings(".plans (PlanLookup)", p.routes[2].chain[1].name);
    try testing.expectEqual(0, p.routes[5].chain.len);

    // The parameters of each pattern, in order.
    try testing.expectEqual(0, p.routes[0].params.len);
    try testing.expectEqualStrings("id", p.routes[1].params[0]);
    try testing.expectEqualStrings("id", p.routes[3].params[0]);
    try testing.expectEqualStrings("path", p.routes[3].params[1]);
}

test "plan: messages print types without their files" {
    try testing.expectEqualStrings("UsersV1Controller", comptime typeName(UsersV1Controller));
    try testing.expectEqualStrings("*const UsersV1Controller", comptime typeName(*const UsersV1Controller));
    try testing.expectEqualStrings("fn (*UsersV1Controller, *http.Context) !void", comptime fnForm(@TypeOf(UsersV1Controller.list)));
    try testing.expectEqualStrings("fn (*UsersV1Controller, *http.Context) void", comptime fnForm(@TypeOf(UsersV1Controller.files)));
    try testing.expectEqualStrings("fn (*UsersV1Controller, *const http.sse.Context) void", comptime fnForm(fn (*UsersV1Controller, *const sse.Context) void));
    // The types of zefir-http as the application names them.
    try testing.expectEqualStrings("fn (*UsersV1Controller, *http.Context) !http.Json(Todo)", comptime fnForm(fn (*UsersV1Controller, *Context) anyerror!Json(Todo)));
    try testing.expectEqualStrings("fn (anyerror) http.ErrorResponse(http.Problem)", comptime fnForm(fn (anyerror) errors.ErrorResponse(errors.Problem)));
    try testing.expectEqualStrings("*http.ErrorResponse(Todo)", comptime typeName(*errors.ErrorResponse(Todo)));
    try testing.expectEqualStrings("http.ErrorAction", comptime typeName(errors.ErrorAction));
    try testing.expectEqualStrings("Json(plan.UsersV1Controller.get__struct_0)", comptime shortName("http.dto.Json(plan.UsersV1Controller.get__struct_0)"));
}
