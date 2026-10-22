//! The server, described at compile time:
//! `http.describe(@TypeOf(parts))` gives what `http.Server.init` builds
//! from parts of that type, for a generator of documents such as
//! zefir-openapi. It reads the plan the server builds: the routes in their
//! order, the declarations of each, its chain of middleware and the errors
//! it can return, and the error handler. The settings of the server, its
//! `http.Server.Options`, are values the program gets when it runs, so
//! they are not in it.
//!
//! Nothing here runs unless it is called: a server whose application
//! builds no document does not pay for it.
//!
//! ```zig
//! const d = comptime http.describe(@TypeOf(parts));
//! for (d.routes) |r| ... // r.method, r.template, r.Route.Path, r.Errors, ...
//! ```
const std = @import("std");
const v = @import("validator");
const plan = @import("plan.zig");
const routes = @import("routes.zig");
const router = @import("router.zig");
const mw = @import("middleware.zig");
const strings = @import("input/strings.zig");

/// One element of a chain of middleware.
pub const ChainElement = struct {
    /// As the log and `http.testing.chainNames` name it: requestId,
    /// AccessLog, requirePermission(todos), .audit (Audit).
    name: []const u8,
    /// The type whose phases run: a type element, the type made of a
    /// function, or the type of the object.
    Impl: type,
};

/// One route of the server.
pub const RouteDescription = struct {
    method: std.http.Method,
    kind: routes.Kind,
    /// The controller's prefix and the route's path, as declared:
    /// "/v1/todos/{id}"; the server's prefix is not in it.
    template: []const u8,
    /// The names of the template's parameters, in order, `{*rest}` as
    /// "rest".
    params: []const []const u8,
    /// The last parameter is `{*name}`, the rest of the path.
    catch_all: bool,
    Controller: type,
    /// "TodosV1Controller".
    controller_name: []const u8,
    /// The controller's method that handles the route: "create".
    handler: []const u8,
    /// The route as `http.get` and the others made it, with its
    /// declarations: `Path`, `Query`, `Body`, `Form`, `Headers`, `Cookies`,
    /// `Events` and `responses`.
    Route: type,
    /// The `T` of the `http.Json(T)` its handler returns; void for a
    /// handler of `!void` and for SSE.
    Value: type,
    /// The server's elements, then the controller's, then the method's,
    /// sets unfolded: the order every phase runs them in.
    chain: []const ChainElement,
    /// Every error the route can give the error handler: those of its
    /// handler, of the transforms of its `Value`, and of the `run` of each
    /// element of its chain.
    Errors: type,
};

/// The server that parts of one type build.
pub const Description = struct {
    /// In the order of `.controllers`, each in the order of its `.methods`.
    routes: []const RouteDescription,
    /// The type of the object `.error_handler` points to, or the default
    /// error handler.
    ErrorHandler: type,
    /// The body of the responses of its `mapError`: `http.Problem` for the
    /// default one.
    ErrorBody: type,
    /// The server's middleware, sets unfolded.
    global: []const ChainElement,

    /// The header that a field of a DTO of headers reads:
    /// "idempotency_key" is "Idempotency-Key".
    pub fn headerName(comptime field: []const u8) []const u8 {
        return strings.headerName(field);
    }
};

/// The server that `http.Server.init` builds from parts of type `Parts`,
/// at compile time. It checks them as `Server.init` does, and raises its
/// own eval branch quota by its work: the application sets none.
pub fn describe(comptime Parts: type) Description {
    comptime {
        const p = plan.of(Parts);
        var elements: u64 = 0;
        for (p.routes) |r| elements += p.global.len + r.chain.len;
        @setEvalBranchQuota(@intCast(@min(10_000 + 2_000 * p.routes.len + 200 * elements, std.math.maxInt(u32))));
        const global = chainOf(p.global);
        var out: []const RouteDescription = &.{};
        for (p.routes) |r| {
            const Handler = @TypeOf(@field(r.Controller, r.handler));
            const Payload = payloadOf(@typeInfo(Handler).@"fn".return_type.?);
            const Value = if (Payload == void) void else Payload.Value;
            const segments = router.parse(r.pattern, r.controller_name ++ "." ++ r.handler);
            out = out ++ [_]RouteDescription{.{
                .method = r.method,
                .kind = r.kind,
                .template = r.pattern,
                .params = r.params,
                .catch_all = segments.len > 0 and segments[segments.len - 1] == .catch_all,
                .Controller = r.Controller,
                .controller_name = r.controller_name,
                .handler = r.handler,
                .Route = r.Route,
                .Value = Value,
                .chain = global ++ chainOf(r.chain),
                .Errors = RouteErrors(r.Controller, r.handler, p.global ++ r.chain),
            }};
        }
        const Map = @typeInfo(@TypeOf(p.Handler.mapError)).@"fn".return_type.?;
        return .{
            .routes = out,
            .ErrorHandler = p.Handler,
            .ErrorBody = Map.Body,
            .global = global,
        };
    }
}

/// The errors the route of the handler `handler` of `C` can give the error
/// handler: those of the handler, of the transforms of the value of the
/// `http.Json(T)` it returns, and of the `run` of each element of its
/// chain, the server's elements included.
pub fn RouteErrors(comptime C: type, comptime handler: []const u8, comptime chain: []const mw.Elem) type {
    const Handler = @TypeOf(@field(C, handler));
    const Payload = payloadOf(@typeInfo(Handler).@"fn".return_type.?);
    var Errors: type = mw.ErrorSetOf(Handler);
    if (Payload != void) Errors = Errors || v.TransformError(Payload.Value);
    for (chain) |e| {
        if (@hasDecl(e.Impl, "run")) Errors = Errors || mw.ErrorSetOf(@TypeOf(e.Impl.run));
    }
    return Errors;
}

fn chainOf(comptime elems: []const mw.Elem) []const ChainElement {
    var out: [elems.len]ChainElement = undefined;
    for (elems, &out) |e, *element| element.* = .{ .name = e.name, .Impl = e.Impl };
    const final = out;
    return &final;
}

fn payloadOf(comptime R: type) type {
    return if (@typeInfo(R) == .error_union) @typeInfo(R).error_union.payload else R;
}

const testing = std.testing;
const Context = @import("Context.zig");
const sse = @import("sse.zig");
const errors = @import("errors.zig");
const Json = @import("dto.zig").Json;

// Application code of the tests: zefir-http ships no middleware.
fn requestId(_: *Context) error{NoRequestId}!mw.MiddlewareResult {
    return .next;
}
const Audit = struct {
    pub fn onFinish(_: *Audit, _: *Context, _: mw.Outcome) !void {}
};
const PlanLookup = struct {
    pub fn run(_: *PlanLookup, _: *Context) error{PlanMissing}!mw.MiddlewareResult {
        return .next;
    }
};
var audit_object: Audit = .{};
var plans_object: PlanLookup = .{};

const UserPath = struct { id: u64 };
const UserFilePath = struct { id: u64, path: []const u8 };
const UserQuery = struct { page: u32 = 1 };
const CreateUser = struct { name: []const u8 };
/// Its transform has an error of its own, which the writing of a response
/// can return.
const UserResponse = struct {
    id: u64,
    name: []const u8,
    pub const field_rules = .{ .name = v.transformWith(refuseEmpty) };
};

fn refuseEmpty(_: std.mem.Allocator, name: []const u8) error{EmptyName}![]const u8 {
    if (name.len == 0) return error.EmptyName;
    return name;
}

/// The events of the users' stream.
const UserEvent = union(enum) { joined: UserResponse, left: void };

const UsersV1Controller = struct {
    audit: *Audit = &audit_object,
    plans: *PlanLookup = &plans_object,

    const Create = routes.post("", .{ .body = CreateUser, .responses = .{ .created = .{}, .ok = .{} }, .middleware = .{.plans} });

    pub const http_routes = routes.routes(.{
        .prefix = "/v1/users",
        .middleware = .{.audit},
        .methods = .{
            .list = routes.get("", .{ .query = UserQuery }),
            .get = routes.get("/{id}", .{ .path = UserPath }),
            .create = Create,
            .files = routes.get("/{id}/files/{*path}", .{ .path = UserFilePath }),
            .events = sse.get("/events", .{ .events = UserEvent }),
        },
    });

    pub fn list(_: *UsersV1Controller, _: *Context) !void {}
    pub fn get(_: *UsersV1Controller, _: *Context) error{UserNotFound}!Json(UserResponse) {
        return error.UserNotFound;
    }
    pub fn create(_: *UsersV1Controller, ctx: *Context) !Json(UserResponse) {
        const in = try ctx.input(Create);
        return .{ .value = .{ .id = 1, .name = in.body.name }, .status = 201 };
    }
    pub fn files(_: *UsersV1Controller, _: *Context) void {}
    pub fn events(_: *UsersV1Controller, _: *sse.Context) !void {}
};

const HealthController = struct {
    pub const http_routes = routes.routes(.{ .methods = .{ .check = routes.get("/health", .{}) } });

    pub fn check(_: *HealthController, _: *Context) !void {}
};

const ApiError = struct { code: []const u8 };

/// Maps every error of the application.
const AppErrors = struct {
    pub fn mapError(err: anyerror) errors.ErrorResponse(ApiError) {
        return switch (err) {
            error.UserNotFound => .{ .status = 404, .body = .{ .code = "users.not_found" } },
            error.NoRequestId, error.PlanMissing, error.EmptyName => .{ .status = 500, .body = .{ .code = "internal" } },
            else => .fallback(err, .{ .code = errors.defaultCode(err) }),
        };
    }
};

/// The names of `E`, sorted.
fn errorNames(comptime E: type) []const []const u8 {
    var out: []const []const u8 = &.{};
    for (@typeInfo(E).error_set.error_names.?) |name| {
        var at: usize = 0;
        while (at < out.len and std.mem.order(u8, out[at], name) == .lt) at += 1;
        out = out[0..at] ++ [_][]const u8{name} ++ out[at..];
    }
    return out;
}

fn hasError(comptime E: type, comptime name: []const u8) bool {
    for (@typeInfo(E).error_set.error_names.?) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

test "describe: the routes in the order of the controllers and their methods, with their declarations" {
    var users: UsersV1Controller = .{};
    var health: HealthController = .{};
    var app_errors: AppErrors = .{};
    const d = comptime describe(@TypeOf(.{ .controllers = .{ &users, &health }, .error_handler = &app_errors }));
    try testing.expectEqual(6, d.routes.len);
    const want = [_]struct { std.http.Method, routes.Kind, []const u8, []const u8, bool }{
        .{ .GET, .rest, "/v1/users", "list", false },
        .{ .GET, .rest, "/v1/users/{id}", "get", false },
        .{ .POST, .rest, "/v1/users", "create", false },
        .{ .GET, .rest, "/v1/users/{id}/files/{*path}", "files", true },
        .{ .GET, .sse, "/v1/users/events", "events", false },
        .{ .GET, .rest, "/health", "check", false },
    };
    inline for (want, d.routes) |w, r| {
        try testing.expectEqual(w[0], r.method);
        try testing.expectEqual(w[1], r.kind);
        try testing.expectEqualStrings(w[2], r.template);
        try testing.expectEqualStrings(w[3], r.handler);
        try testing.expectEqual(w[4], r.catch_all);
    }
    try testing.expect(d.routes[0].Controller == UsersV1Controller and d.routes[5].Controller == HealthController);
    try testing.expectEqualStrings("UsersV1Controller", d.routes[0].controller_name);
    try testing.expectEqualStrings("HealthController", d.routes[5].controller_name);
    // The parameters, `{*path}` by its name.
    try testing.expectEqual(2, d.routes[3].params.len);
    try testing.expectEqualStrings("id", d.routes[3].params[0]);
    try testing.expectEqualStrings("path", d.routes[3].params[1]);
    // The routes with their declarations.
    try testing.expect(d.routes[0].Route.Query == UserQuery);
    try testing.expect(d.routes[1].Route.Path == UserPath);
    try testing.expect(d.routes[2].Route == UsersV1Controller.Create);
    try testing.expectEqual(2, d.routes[2].Route.responses.len);
    // The events of the stream; void on the other routes.
    try testing.expect(d.routes[4].Route.Events == UserEvent and d.routes[2].Route.Events == void);
    // The value of a JSON handler; void for !void and for SSE.
    try testing.expect(d.routes[1].Value == UserResponse and d.routes[2].Value == UserResponse);
    try testing.expect(d.routes[0].Value == void and d.routes[3].Value == void and d.routes[4].Value == void);
}

test "describe: the chain of each route and the errors it can return" {
    var users: UsersV1Controller = .{};
    var app_errors: AppErrors = .{};
    const d = comptime describe(@TypeOf(.{ .controllers = .{&users}, .middleware = .{requestId}, .error_handler = &app_errors }));
    try testing.expectEqual(1, d.global.len);
    try testing.expectEqualStrings("requestId", d.global[0].name);
    // The server's elements, the controller's, the method's.
    const create = d.routes[2];
    try testing.expectEqual(3, create.chain.len);
    inline for (.{ "requestId", ".audit (Audit)", ".plans (PlanLookup)" }, create.chain) |name, e| try testing.expectEqualStrings(name, e.name);
    try testing.expect(create.chain[1].Impl == Audit and create.chain[2].Impl == PlanLookup);
    try testing.expectEqual(2, d.routes[1].chain.len);

    // The handler's errors, those of the transforms of its value, and of
    // the run of each element; not those of another route's elements.
    const get = d.routes[1].Errors;
    try testing.expect(comptime hasError(get, "UserNotFound") and hasError(get, "EmptyName") and hasError(get, "NoRequestId"));
    try testing.expect(comptime !hasError(get, "PlanMissing"));
    const create_errors = create.Errors;
    try testing.expect(comptime hasError(create_errors, "PlanMissing") and hasError(create_errors, "NoRequestId") and hasError(create_errors, "EmptyName"));
    // Those of ctx.input(Create): its body.
    try testing.expect(comptime hasError(create_errors, "ValidationFailed") and hasError(create_errors, "UnsupportedMediaType"));
    // A handler of void and an element without run add nothing.
    try testing.expectEqualStrings("NoRequestId", comptime errorNames(d.routes[3].Errors)[0]);
    try testing.expectEqual(1, comptime errorNames(d.routes[3].Errors).len);
}

test "describe: the error handler and the body of its responses" {
    var users: UsersV1Controller = .{};
    var app_errors: AppErrors = .{};
    const mapped = comptime describe(@TypeOf(.{ .controllers = .{&users}, .error_handler = &app_errors }));
    try testing.expect(mapped.ErrorHandler == AppErrors and mapped.ErrorBody == ApiError);
    // Without .error_handler: the default one, and problem+json.
    var health: HealthController = .{};
    const default = comptime describe(@TypeOf(.{ .controllers = .{&health} }));
    try testing.expect(default.ErrorHandler == errors.DefaultErrors and default.ErrorBody == errors.Problem);
}

test "describe: the header of a field of headers" {
    try testing.expectEqualStrings("Idempotency-Key", comptime Description.headerName("idempotency_key"));
    try testing.expectEqualStrings("X-Request-Id", comptime Description.headerName("x_request_id"));
}
