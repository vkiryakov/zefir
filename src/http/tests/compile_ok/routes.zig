//! Must compile: every kind of route and each of its options, declared by
//! client code and passed to Server.init with a prefix from the config,
//! every kind of middleware element, and an error handler with `mapError`
//! and `handle`, which maps the error of `create`; handlers that read their
//! declared input with `ctx.input`, and the server described for a
//! document with `http.describe`.
const std = @import("std");
const http = @import("http");

const TodoResponse = struct { id: u64, title: []const u8 };

// The input that routes declare.
const TodoIdPath = struct { id: u64 };
const TodoFilePath = struct { id: u64, path: []const u8 };
const ListTodosQuery = struct { page: u32 = 1, done: ?bool = null };
const CreateTodoRequest = struct { title: []const u8 };
const CreateTodoHeaders = struct { idempotency_key: ?[]const u8 = null };
const LoginForm = struct { user: []const u8, password: []const u8 };
const SessionCookies = struct { session: ?[]const u8 = null };
/// The events of the todos' stream: a todo, or nothing at all.
const TodoEvent = union(enum) { @"todo.created": TodoResponse, @"todo.cleared": void };

/// Timeouts of a config: a duration, or none.
const report_timeout: ?std.Io.Duration = std.Io.Duration.fromSeconds(60);
const archive_timeout: ?std.Io.Duration = null;

// Application code (src/middleware.zig of a client): zefir-http ships none of these.
fn requestId(ctx: *http.Context) !http.MiddlewareResult {
    try ctx.response.setHeader("x-request-id", ctx.requestId());
    return .next;
}
fn noCache(ctx: *http.Context) !void {
    try ctx.response.setHeader("cache-control", "no-store");
}
fn countRequest(_: *http.Context, _: http.Outcome) !void {}
const Typed = struct {
    pub const name = "Typed";
    pub fn run(_: *http.Context) http.MiddlewareResult {
        return .next;
    }
    pub fn onFinish(_: *http.Context, _: http.Outcome) void {}
};
const AccessLog = struct {
    pub fn onFinish(_: *const AccessLog, _: *http.Context, _: http.Outcome) !void {}
};
const Audit = struct {
    pub fn run(_: *Audit, _: *http.Context) !http.MiddlewareResult {
        return .next;
    }
    pub fn onFinish(_: *Audit, _: *http.Context, _: http.Outcome) !void {}
};

const TodosV1Controller = struct {
    calls: u32 = 0,
    audit: *Audit,

    // Named, so that the handlers read their input through them.
    const Get = http.get("/{id}", .{ .path = TodoIdPath });
    const Create = http.post("", .{
        .body = CreateTodoRequest,
        .headers = CreateTodoHeaders,
        .responses = .{ .created = .{}, .ok = .{} },
        .max_body_bytes = 64 << 10,
        .middleware = .{.audit},
    });
    const Login = http.post("/login", .{ .form = LoginForm, .cookies = SessionCookies, .responses = .{ .see_other = .{} } });
    const Events = http.sse.get("/events", .{ .events = TodoEvent, .query = ListTodosQuery, .heartbeat = std.Io.Duration.fromSeconds(15), .on_close = .eventsClosed });

    pub const http_routes = http.routes(.{
        .prefix = "/v1/todos",
        .middleware = .{.audit},
        .methods = .{
            .list = http.get("", .{ .query = ListTodosQuery }),
            .get = Get,
            .create = Create,
            .login = Login,
            .replace = http.put("/{id}", .{ .timeout = null }),
            .update = http.patch("/{id}", .{}),
            .remove = http.delete("/{id}", .{ .path = TodoIdPath, .responses = .{ .no_content = .{}, .conflict = .{ .json = ApiError } } }),
            .probe = http.head("/{id}", .{}),
            .preflight = http.options("/{id}", .{}),
            .exportCsv = http.get("/export.csv", .{ .timeout = std.Io.Duration.fromSeconds(300), .responses = .{ .ok = .{ .content_type = "text/csv" } } }),
            .report = http.get("/report", .{ .timeout = report_timeout }),
            .archive = http.get("/archive", .{ .timeout = archive_timeout }),
            .files = http.get("/{id}/files/{*path}", .{ .path = TodoFilePath }),
            .events = Events,
        },
    });

    pub fn list(_: *TodosV1Controller, _: *http.Context) !void {}
    pub fn get(_: *TodosV1Controller, ctx: *http.Context) !http.Json(TodoResponse) {
        const in = try ctx.input(Get);
        return .{ .value = .{ .id = in.path.id, .title = "Buy milk" } };
    }
    pub fn create(_: *TodosV1Controller, ctx: *http.Context) !http.Json(TodoResponse) {
        const in = try ctx.input(Create);
        if (in.headers.idempotency_key == null) return error.TodoLimitReached;
        return .{ .value = .{ .id = 2, .title = titleOf(in) }, .status = 201 };
    }
    pub fn login(_: *TodosV1Controller, ctx: *http.Context) !void {
        const in = try ctx.input(Login);
        _ = in.form.user;
        _ = in.cookies.session;
    }
    pub fn replace(_: *TodosV1Controller, _: *http.Context) !void {}
    pub fn update(_: *TodosV1Controller, _: *http.Context) !void {}
    pub fn remove(_: *TodosV1Controller, _: *http.Context) !void {}
    pub fn probe(_: *TodosV1Controller, _: *http.Context) !void {}
    pub fn preflight(_: *TodosV1Controller, _: *http.Context) !void {}
    pub fn exportCsv(_: *TodosV1Controller, _: *http.Context) !void {}
    pub fn report(_: *TodosV1Controller, _: *http.Context) !void {}
    pub fn archive(_: *TodosV1Controller, _: *http.Context) !void {}
    pub fn files(_: *TodosV1Controller, _: *http.Context) void {}
    pub fn events(_: *TodosV1Controller, ctx: *http.sse.Context) !void {
        const in = try ctx.input(Events);
        _ = in.query.page;
    }
    pub fn eventsClosed(_: *TodosV1Controller, _: *http.sse.Context) void {}
};

/// What `ctx.input(Create)` gives, as a type of its own.
fn titleOf(in: http.Input(TodosV1Controller.Create)) []const u8 {
    return in.body.title;
}

const ApiError = struct {
    code: []const u8,
    message: []const u8,
    details: []const http.Violation = &.{},
    trace_id: []const u8 = "",
};

const AppErrors = struct {
    pub fn mapError(err: anyerror) http.ErrorResponse(ApiError) {
        return switch (err) {
            error.TodoLimitReached => .{ .status = 409, .body = .{ .code = "todos.limit_reached", .message = "Too many todos" } },
            error.ValidationFailed => .{ .status = 422, .body = .{ .code = "validation_failed", .message = "Invalid request" } },
            else => .fallback(err, .{ .code = http.defaultCode(err), .message = http.defaultTitle(err) }),
        };
    }

    pub fn handle(_: *AppErrors, ctx: *http.Context, err: anyerror, res: *http.ErrorResponse(ApiError)) !http.ErrorAction {
        res.body.trace_id = ctx.traceId();
        if (err == error.ValidationFailed) res.body.details = ctx.violations();
        if (err == error.Unauthenticated) try ctx.response.setHeader("www-authenticate", "Bearer");
        return .respond;
    }
};

const HealthController = struct {
    pub const http_routes = http.routes(.{ .methods = .{ .check = http.get("/health", .{}) } });

    pub fn check(_: *HealthController, _: *http.Context) !void {}
};

fn serve(gpa: std.mem.Allocator, prefix: []const u8) http.Server.InitError!void {
    var audit: Audit = .{};
    var access_log: AccessLog = .{};
    var todos_v1: TodosV1Controller = .{ .audit = &audit };
    var health: HealthController = .{};
    var app_errors: AppErrors = .{};
    const backend: http.Backend = undefined;
    const parts = .{
        .controllers = .{ &todos_v1, &health },
        .middleware = .{ requestId, &access_log, .{ http.onResponse(noCache), .{ Typed, http.onFinish(countRequest) } } },
        .error_handler = &app_errors,
    };
    // The server for a document: its routes, from the type of its parts.
    const described = comptime http.describe(@TypeOf(parts));
    comptime std.debug.assert(described.routes.len == 15);
    var server = try http.Server.init(gpa, parts, .{
        .listen = .{ .backend = backend },
        .prefix = prefix,
    });
    defer server.deinit(std.testing.io);
    const info: http.RouteInfo = server.internal.routes[0].info;
    _ = info;
}

test {
    try serve(std.testing.allocator, "/api");
}
