//! Must compile: every kind of route and each of its options, declared by
//! client code and passed to Server.init with a prefix from the config,
//! every kind of middleware element, and the error handler of design
//! section 11, which maps the error of `create`.
const std = @import("std");
const http = @import("http");

const TodoResponse = struct { id: u64, title: []const u8 };

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

    pub const http_routes = http.routes(.{
        .prefix = "/v1/todos",
        .middleware = .{.audit},
        .methods = .{
            .list = http.get("", .{}),
            .get = http.get("/{id}", .{}),
            .create = http.post("", .{ .max_body_bytes = 64 << 10, .middleware = .{.audit} }),
            .replace = http.put("/{id}", .{ .timeout = null }),
            .update = http.patch("/{id}", .{}),
            .remove = http.delete("/{id}", .{}),
            .probe = http.head("/{id}", .{}),
            .preflight = http.options("/{id}", .{}),
            .exportCsv = http.get("/export.csv", .{ .timeout = std.Io.Duration.fromSeconds(300) }),
            .files = http.get("/{id}/files/{*path}", .{}),
            .events = http.sse.get("/events", .{ .heartbeat = std.Io.Duration.fromSeconds(15), .on_close = .eventsClosed }),
        },
    });

    pub fn list(_: *TodosV1Controller, _: *http.Context) !void {}
    pub fn get(_: *TodosV1Controller, _: *http.Context) !http.Json(TodoResponse) {
        return .{ .value = .{ .id = 1, .title = "Buy milk" } };
    }
    pub fn create(_: *TodosV1Controller, _: *http.Context) error{TodoLimitReached}!http.Json(TodoResponse) {
        return .{ .value = .{ .id = 2, .title = "Buy bread" }, .status = 201 };
    }
    pub fn replace(_: *TodosV1Controller, _: *http.Context) !void {}
    pub fn update(_: *TodosV1Controller, _: *http.Context) !void {}
    pub fn remove(_: *TodosV1Controller, _: *http.Context) !void {}
    pub fn probe(_: *TodosV1Controller, _: *http.Context) !void {}
    pub fn preflight(_: *TodosV1Controller, _: *http.Context) !void {}
    pub fn exportCsv(_: *TodosV1Controller, _: *http.Context) !void {}
    pub fn files(_: *TodosV1Controller, _: *http.Context) void {}
    pub fn events(_: *TodosV1Controller, _: *http.sse.Context) !void {}
    pub fn eventsClosed(_: *TodosV1Controller, _: *http.sse.Context) void {}
};

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
    var server = try http.Server.init(gpa, .{
        .backend = backend,
        .prefix = prefix,
        .controllers = .{ &todos_v1, &health },
        .middleware = .{ requestId, &access_log, .{ http.onResponse(noCache), .{ Typed, http.onFinish(countRequest) } } },
        .error_handler = &app_errors,
    });
    defer server.deinit(std.testing.io);
    const info: http.RouteInfo = server.routes[0].info;
    _ = info;
}

test {
    try serve(std.testing.allocator, "/api");
}
