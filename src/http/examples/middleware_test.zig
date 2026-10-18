// Application code (src/middleware_test.zig of the example app): zefir-http ships none of these.
//! Tests of the example app's authentication and CORS without a network:
//! `http.testing.Backend` serves the same server and the same controllers
//! from memory. The settings come through confy, as in `main`, here from
//! an environment of the test's own.

const std = @import("std");
const confy = @import("confy");
const http = @import("http");
const auth = @import("auth.zig");
const Cors = @import("cors.zig").Cors;

const testing = std.testing;

/// The settings of the example app: the tokens of its two users and the
/// origin of its web page.
const Config = struct {
    auth: struct {
        /// APP_AUTH_ANN_TOKEN: Ann may read and delete todos.
        ann_token: confy.Secret,
        /// APP_AUTH_BOB_TOKEN: Bob may only read them.
        bob_token: confy.Secret,
    },
    cors_origin: []const u8 = "https://app.example",
};

/// The todos: every method needs a user with the permission "todos", and
/// deleting one needs "todos:delete" too.
const TodosV1Controller = struct {
    pub const http_routes = http.routes(.{
        .prefix = "/v1/todos",
        .middleware = .{ auth.requireUser, auth.requirePermission("todos") },
        .methods = .{
            .list = http.get("", .{}),
            .delete = http.delete("/{id}", .{ .middleware = .{auth.requirePermission("todos:delete")} }),
        },
    });

    pub fn list(_: *TodosV1Controller, ctx: *http.Context) !void {
        const user = try ctx.local(auth.CurrentUser);
        try ctx.response.text(user.id);
    }
    pub fn delete(_: *TodosV1Controller, _: *http.Context) !void {}
};

/// Open to anybody: no `requireUser` here.
const HealthController = struct {
    pub const http_routes = http.routes(.{ .methods = .{ .check = http.get("/health", .{}) } });

    pub fn check(_: *HealthController, _: *http.Context) !void {}
};

const ApiError = struct { code: []const u8, message: []const u8 };

/// The app's error handler: its own format, and `WWW-Authenticate` on every
/// 401, which RFC 9110 asks for.
const AppErrors = struct {
    pub fn mapError(err: anyerror) http.ErrorResponse(ApiError) {
        return .fallback(err, .{ .code = http.defaultCode(err), .message = http.defaultTitle(err) });
    }

    pub fn handle(_: *AppErrors, ctx: *http.Context, err: anyerror, _: *http.ErrorResponse(ApiError)) !http.ErrorAction {
        if (err == error.Unauthenticated) try ctx.response.setHeader("www-authenticate", "Bearer");
        return .respond;
    }
};

/// The app as `main` builds it, on the backend in memory.
const App = struct {
    arena: std.heap.ArenaAllocator,
    config: Config = undefined,
    users: [2]auth.TokenAuth.User = undefined,
    origins: [1][]const u8 = undefined,
    token_auth: auth.TokenAuth = undefined,
    cors: Cors = undefined,
    todos_v1: TodosV1Controller = .{},
    health: HealthController = .{},
    app_errors: AppErrors = .{},
    backend: http.testing.Backend,
    server: http.Server = undefined,

    /// Starts the app with the settings of `environ`; `app` stays where it
    /// is until `stop`.
    fn start(app: *App, environ: *const std.process.Environ.Map) !void {
        app.* = .{ .arena = .init(testing.allocator), .backend = .init(testing.allocator) };
        errdefer app.arena.deinit();
        try confy.load(app.arena.allocator(), &app.config, .{
            .io = testing.io,
            .environ = environ,
            .env_prefix = "APP_",
            .sources = &.{.osEnv()},
        });
        app.users = .{
            .{ .token = app.config.auth.ann_token, .id = "ann", .permissions = &.{ "todos", "todos:delete" } },
            .{ .token = app.config.auth.bob_token, .id = "bob", .permissions = &.{"todos"} },
        };
        app.token_auth = .{ .users = &app.users };
        app.origins = .{app.config.cors_origin};
        app.cors = .{ .origins = &app.origins };
        app.server = try .init(testing.allocator, .{
            .backend = app.backend.backend(),
            .prefix = "/api",
            .controllers = .{ &app.todos_v1, &app.health },
            // CORS first: a preflight needs no user.
            .middleware = .{ &app.cors, &app.token_auth },
            .error_handler = &app.app_errors,
        });
        app.server.start(testing.io) catch |err| {
            app.server.deinit(testing.io);
            return err;
        };
    }

    fn stop(app: *App) void {
        app.server.deinit(testing.io);
        app.backend.deinit();
        app.arena.deinit();
    }

    fn request(app: *App, method: std.http.Method, target: []const u8, headers: []const [2][]const u8) !http.testing.Response {
        return app.backend.request(testing.io, .{ .method = method, .target = target, .headers = headers });
    }
};

/// The environment of the tests: the two tokens.
fn testEnviron() !std.process.Environ.Map {
    var environ: std.process.Environ.Map = .init(testing.allocator);
    errdefer environ.deinit();
    try environ.put("APP_AUTH_ANN_TOKEN", "ann-secret");
    try environ.put("APP_AUTH_BOB_TOKEN", "bob-secret");
    return environ;
}

fn codeOf(res: *http.testing.Response) ![]const u8 {
    return (try std.json.parseFromSliceLeaky(ApiError, res.arena.allocator(), res.body, .{})).code;
}

test "TokenAuth: no token is anonymous; requireUser is 401 and the app's handle adds WWW-Authenticate; requirePermission is 403" {
    var environ = try testEnviron();
    defer environ.deinit();
    var app: App = undefined;
    try app.start(&environ);
    defer app.stop();

    // No token: anonymous, and a route without requireUser serves it.
    var health = try app.request(.GET, "/api/health", &.{});
    defer health.deinit();
    try testing.expectEqual(204, health.status);

    // A route behind requireUser: 401 with WWW-Authenticate, without a
    // token and with one nobody has.
    for ([_][]const [2][]const u8{ &.{}, &.{.{ "authorization", "Bearer guess" }} }) |headers| {
        var refused = try app.request(.GET, "/api/v1/todos", headers);
        defer refused.deinit();
        try testing.expectEqual(401, refused.status);
        try testing.expectEqualStrings("Bearer", refused.header("www-authenticate").?);
        try testing.expectEqualStrings("unauthenticated", try codeOf(&refused));
    }

    // A known token, as a bearer token or as the session cookie.
    var bob = try app.request(.GET, "/api/v1/todos", &.{.{ "authorization", "Bearer bob-secret" }});
    defer bob.deinit();
    try testing.expectEqual(200, bob.status);
    try testing.expectEqualStrings("bob", bob.body);
    var cookie = try app.request(.GET, "/api/v1/todos", &.{.{ "cookie", "theme=dark; session=ann-secret" }});
    defer cookie.deinit();
    try testing.expectEqualStrings("ann", cookie.body);

    // Bob may not delete: 403, without WWW-Authenticate; Ann may.
    var denied = try app.request(.DELETE, "/api/v1/todos/1", &.{.{ "authorization", "Bearer bob-secret" }});
    defer denied.deinit();
    try testing.expectEqual(403, denied.status);
    try testing.expectEqualStrings("permission_denied", try codeOf(&denied));
    try testing.expectEqual(null, denied.header("www-authenticate"));
    var deleted = try app.request(.DELETE, "/api/v1/todos/1", &.{.{ "authorization", "Bearer ann-secret" }});
    defer deleted.deinit();
    try testing.expectEqual(204, deleted.status);
}

test "Cors: preflight 204; an error response carries Access-Control-Allow-Origin; Vary: Origin on every response but with *; no * with credentials" {
    var environ = try testEnviron();
    defer environ.deinit();
    var app: App = undefined;
    try app.start(&environ);
    defer app.stop();
    const origin = "https://app.example";

    // The preflight of a page of its origin: 204, no body, no user needed.
    var preflight = try app.request(.OPTIONS, "/api/v1/todos/1", &.{
        .{ "origin", origin },
        .{ "access-control-request-method", "DELETE" },
        .{ "access-control-request-headers", "authorization" },
    });
    defer preflight.deinit();
    try testing.expectEqual(204, preflight.status);
    try testing.expectEqualStrings("", preflight.body);
    try testing.expectEqualStrings(origin, preflight.header("access-control-allow-origin").?);
    try testing.expectEqualStrings("GET, HEAD, POST, PUT, PATCH, DELETE", preflight.header("access-control-allow-methods").?);
    try testing.expectEqualStrings("authorization, content-type, idempotency-key", preflight.header("access-control-allow-headers").?);
    try testing.expectEqualStrings("true", preflight.header("access-control-allow-credentials").?);
    try testing.expectEqualStrings("Origin", preflight.header("vary").?);

    // The preflight of an origin it does not list gets none of it: the
    // server answers OPTIONS itself, and the browser refuses the call.
    var stranger = try app.request(.OPTIONS, "/api/v1/todos/1", &.{
        .{ "origin", "https://evil.example" },
        .{ "access-control-request-method", "DELETE" },
    });
    defer stranger.deinit();
    try testing.expectEqual(204, stranger.status);
    try testing.expectEqual(null, stranger.header("access-control-allow-origin"));
    try testing.expectEqualStrings("DELETE, OPTIONS", stranger.header("allow").?);
    // The answer depends on Origin all the same, and so does that of a
    // request without one: a cache must keep them apart.
    try testing.expectEqualStrings("Origin", stranger.header("vary").?);
    var plain = try app.request(.GET, "/api/health", &.{});
    defer plain.deinit();
    try testing.expectEqual(null, plain.header("access-control-allow-origin"));
    try testing.expectEqualStrings("Origin", plain.header("vary").?);

    // The answer to an error carries the headers too, so that the page can
    // read the 401.
    var refused = try app.request(.GET, "/api/v1/todos", &.{.{ "origin", origin }});
    defer refused.deinit();
    try testing.expectEqual(401, refused.status);
    try testing.expectEqualStrings(origin, refused.header("access-control-allow-origin").?);
    try testing.expectEqualStrings("Origin", refused.header("vary").?);
    try testing.expectEqualStrings("x-request-id", refused.header("access-control-expose-headers").?);

    // Any origin: "*", and then never with credentials; the answer is the
    // same for every origin, without Vary.
    const any = [_][]const u8{"*"};
    app.cors = .{ .origins = &any };
    var open = try app.request(.GET, "/api/health", &.{.{ "origin", "https://other.example" }});
    defer open.deinit();
    try testing.expectEqualStrings("*", open.header("access-control-allow-origin").?);
    try testing.expectEqual(null, open.header("access-control-allow-credentials"));
    try testing.expectEqual(null, open.header("vary"));
}
