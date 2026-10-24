//! A golden application of zefir-openapi: security from the middleware of
//! the chains (every kind of scheme, `.any`, schemes by name, roles), the
//! input and the responses of a middleware, a stream of events, a form,
//! a list in a header, cookies, the rest of the path, two parameters of
//! the path with one renamed, and the rows of `.responses`: 201 and 200,
//! 303, `text/csv`, `.json = U`. Its prefix comes from a field, at run
//! time. Its document is src/openapi/tests/golden/secure-3.1.json and
//! -3.2.json.
//!
//! Application code: zefir ships no middleware, DTO or controller.
const std = @import("std");
const zefir = @import("zefir");
const http = zefir.http;
const v = zefir.validator;

pub const Request = @import("request.zig").Request;

// ------------------------------------------------------------------ DTOs

/// Path /v1/projects/{projectId}/todos/{id}.
pub const ProjectTodoPath = struct {
    project_id: u64,
    id: u64,

    pub const field_rules = .{
        .project_id = .{ v.rename("projectId"), v.positive },
        .id = v.positive,
    };

    pub const openapi: zefir.openapi.Doc(@This()) = .{ .fields = .{
        .project_id = .{ .description = "The id of the project.", .example = 7 },
        .id = .{ .description = "The id of the todo in the project.", .example = 42 },
    } };
};

pub const ProjectPath = struct {
    project_id: u64,

    pub const field_rules = .{ .project_id = .{ v.rename("projectId"), v.positive } };

    pub const openapi: zefir.openapi.Doc(@This()) = .{ .fields = .{ .project_id = .{ .description = "The id of the project." } } };
};

/// Path /v1/projects/{projectId}/todos/files/{*path}.
pub const FilePath = struct {
    project_id: u64,
    path: []const u8,

    pub const field_rules = .{ .project_id = v.rename("projectId") };

    pub const openapi: zefir.openapi.Doc(@This()) = .{ .fields = .{ .path = .{ .description = "Where the file is in the project." } } };
};

pub const PageQuery = struct {
    limit: u32 = 20,

    pub const field_rules = .{ .limit = v.range(1, 100) };
};

pub const ConditionalHeaders = struct {
    if_none_match: ?[]const u8 = null,

    pub const openapi: zefir.openapi.Doc(@This()) = .{ .fields = .{ .if_none_match = .{ .description = "The ETag of the page the client has." } } };
};

/// A header that comes in several lines.
pub const TraceHeaders = struct {
    x_trace: []const []const u8 = &.{},
};

pub const Theme = enum { light, dark };

pub const PrefsCookies = struct {
    theme: Theme = .light,
};

pub const CreateHeaders = struct {
    idempotency_key: ?[]const u8 = null,

    pub const field_rules = .{ .idempotency_key = .{ v.trim, v.notBlank, v.maxLength(64) } };

    pub const openapi: zefir.openapi.Doc(@This()) = .{ .fields = .{ .idempotency_key = .{
        .description = "Send the same key again to get the todo made the first time.",
        .example = "3f2b9c1e-7d4a-4f0e-9a61-2c8d5b7e1f30",
    } } };
};

pub const CreateTodoRequest = struct {
    title: []const u8,

    pub const field_rules = .{ .title = .{ v.trim, v.notBlank, v.maxLength(200) } };
};

pub const TodoResponse = struct {
    id: u64,
    title: []const u8,
};

pub const TodoRef = struct { id: u64 };

pub const Receipt = struct {
    count: u32,

    pub const openapi: zefir.openapi.Doc(@This()) = .{ .description = "How many todos the project has." };
};

pub const LoginForm = struct {
    user: []const u8,
    password: []const u8,
    remember: bool = false,

    pub const field_rules = .{ .user = v.notBlank };
};

/// The events of the stream of a project: the name of a variant is the
/// name of the event, its type the event's data.
pub const LiveEvent = union(enum) {
    @"todo.created": TodoResponse,
    @"todo.deleted": TodoRef,
    ping,
};

/// The body of every error.
pub const ApiError = struct {
    code: []const u8,
    message: []const u8,
};

// ------------------------------------------------------------------ middleware

fn signedIn(ctx: *http.Context) bool {
    const token = ctx.request.header("authorization") orelse return false;
    return std.mem.eql(u8, token, "Bearer ann-secret");
}

/// Knows the client: by a bearer token, the cookie of a session or an API
/// key.
pub const TokenAuth = struct {
    pub const openapi: zefir.openapi.MiddlewareDoc = .{
        .security_schemes = &.{
            .{ .name = "bearer", .description = "A token of a signed-in user.", .kind = .{ .http = .{ .scheme = "bearer", .bearer_format = "opaque" } } },
            .{ .name = "session", .kind = .{ .api_key = .{ .in = .cookie, .param = "session" } } },
            .{ .name = "apiKey", .kind = .{ .api_key = .{ .in = .header, .param = "X-Api-Key" } } },
        },
    };

    pub fn run(_: *TokenAuth, _: *http.Context) error{}!http.MiddlewareResult {
        return .next;
    }
};

/// The ways of signing in of other services, for the administration.
pub const Federated = struct {
    pub const openapi: zefir.openapi.MiddlewareDoc = .{
        .security_schemes = &.{
            .{ .name = "oauth", .kind = .{ .oauth2 = .{ .flows = .{
                .implicit = .{
                    .authorization_url = "https://id.example.com/authorize",
                    .scopes = &.{.{ .name = "audit", .description = "Read the audit log." }},
                },
                .password = .{ .token_url = "https://id.example.com/token", .refresh_url = "https://id.example.com/refresh" },
                .client_credentials = .{ .token_url = "https://id.example.com/token" },
                .authorization_code = .{
                    .authorization_url = "https://id.example.com/authorize",
                    .token_url = "https://id.example.com/token",
                    .scopes = &.{.{ .name = "audit", .description = "Read the audit log." }},
                },
            } } } },
            .{ .name = "oidc", .kind = .{ .open_id_connect = .{ .url = "https://id.example.com/.well-known/openid-configuration" } } },
            .{ .name = "mtls", .description = "A certificate of the client.", .kind = .mutual_tls },
        },
    };

    pub fn run(_: *http.Context) error{}!http.MiddlewareResult {
        return .next;
    }
};

/// 401 without a user.
pub const requireUser = struct {
    pub const openapi: zefir.openapi.MiddlewareDoc = .{
        .security = .any,
        .responses = .{ .unauthorized = .{ .description = "Sign in first." } },
    };

    pub fn run(ctx: *http.Context) error{Unauthenticated}!http.MiddlewareResult {
        if (!signedIn(ctx)) return error.Unauthenticated;
        return .next;
    }
};

/// 401 without a bearer token.
pub const requireBearer = struct {
    pub const openapi: zefir.openapi.MiddlewareDoc = .{ .security = .{ .schemes = &.{"bearer"} } };

    pub fn run(ctx: *http.Context) error{Unauthenticated}!http.MiddlewareResult {
        if (!signedIn(ctx)) return error.Unauthenticated;
        return .next;
    }
};

/// 401 without a token of another service.
pub const requireFederated = struct {
    pub const openapi: zefir.openapi.MiddlewareDoc = .{ .security = .{ .schemes = &.{ "oauth", "oidc" } } };

    pub fn run(ctx: *http.Context) error{Unauthenticated}!http.MiddlewareResult {
        if (!signedIn(ctx)) return error.Unauthenticated;
        return .next;
    }
};

/// 403 when the request asks to be denied the permission, `X-Deny`.
pub fn requirePermission(comptime permission: []const u8) type {
    return struct {
        pub const name = "requirePermission(" ++ permission ++ ")";
        pub const openapi: zefir.openapi.MiddlewareDoc = .{ .roles = &.{permission} };

        pub fn run(ctx: *http.Context) error{PermissionDenied}!http.MiddlewareResult {
            const denied = ctx.request.header("x-deny") orelse return .next;
            if (std.mem.eql(u8, denied, permission)) return error.PermissionDenied;
            return .next;
        }
    };
}

/// Reads the size of a page, and answers 304 itself when the client has
/// the page.
pub const Paging = struct {
    pub const openapi: zefir.openapi.MiddlewareDoc = .{
        .query = PageQuery,
        .headers = ConditionalHeaders,
        .responses = .{ .not_modified = .{ .description = "The page did not change since its ETag." } },
    };

    pub fn run(ctx: *http.Context) !http.MiddlewareResult {
        _ = try ctx.query(PageQuery);
        const conditional = try ctx.headers(ConditionalHeaders);
        if (conditional.if_none_match) |etag| if (std.mem.eql(u8, etag, "\"v1\"")) {
            _ = ctx.response.status(304);
            return .handled;
        };
        return .next;
    }
};

// ------------------------------------------------------------------ controllers

pub const ProjectTodosController = struct {
    live: *http.sse.Manager(LiveEvent),

    const List = http.get("", .{ .path = ProjectPath, .headers = TraceHeaders, .cookies = PrefsCookies, .middleware = .{Paging} });
    const Get = http.get("/{id}", .{ .path = ProjectTodoPath });
    const Create = http.post("", .{ .path = ProjectPath, .body = CreateTodoRequest, .headers = CreateHeaders, .responses = .{ .created = .{}, .ok = .{} } });
    const Delete = http.delete("/{id}", .{ .path = ProjectTodoPath, .middleware = .{requirePermission("projects:delete")} });
    const Export = http.get("/export.csv", .{ .path = ProjectPath, .responses = .{ .ok = .{ .content_type = "text/csv" } } });
    const Count = http.get("/count", .{ .path = ProjectPath, .responses = .{ .ok = .{ .json = Receipt } } });
    const Events = http.sse.get("/events", .{ .path = ProjectPath, .events = LiveEvent });
    const Files = http.get("/files/{*path}", .{ .path = FilePath, .responses = .{ .ok = .{ .content_type = "text/plain" } } });

    pub const http_routes = http.routes(.{
        .prefix = "/v1/projects/{projectId}/todos",
        .middleware = .{ requireUser, requirePermission("projects") },
        .methods = .{
            .list = List,
            .get = Get,
            .create = Create,
            .delete = Delete,
            .exportCsv = Export,
            .count = Count,
            .events = Events,
            .files = Files,
        },
    });

    pub const openapi: zefir.openapi.ControllerDoc(@This()) = .{
        .tag = "Todos",
        .description = "The todos of a project.",
        .routes = .{
            .list = .{ .summary = "List the todos of a project" },
            .get = .{ .summary = "Get a todo" },
            .create = .{
                .summary = "Create a todo",
                .description = "A retry with the same Idempotency-Key returns the todo it made.",
                .responses = .{ .ok = .{ .description = "The todo the first request with this key made." } },
            },
            .delete = .{ .summary = "Delete a todo" },
            .exportCsv = .{ .summary = "Export the todos as CSV", .responses = .{ .ok = .{ .description = "The todos, a row each." } } },
            .count = .{ .summary = "Count the todos" },
            .events = .{ .summary = "Live updates" },
            .files = .{ .summary = "Get a file of a project" },
        },
    };

    pub fn list(_: *ProjectTodosController, ctx: *http.Context) !http.Json([]const TodoResponse) {
        _ = try ctx.input(List);
        return .{ .value = &.{.{ .id = 1, .title = "Buy milk" }} };
    }

    pub fn get(_: *ProjectTodosController, ctx: *http.Context) !http.Json(TodoResponse) {
        const in = try ctx.input(Get);
        if (in.path.id != 1) return error.TodoNotFound;
        return .{ .value = .{ .id = 1, .title = "Buy milk" } };
    }

    pub fn create(_: *ProjectTodosController, ctx: *http.Context) !http.Json(TodoResponse) {
        const in = try ctx.input(Create);
        if (in.headers.idempotency_key != null) return .{ .value = .{ .id = 1, .title = in.body.title } };
        return .{ .value = .{ .id = 2, .title = in.body.title }, .status = 201 };
    }

    pub fn delete(_: *ProjectTodosController, ctx: *http.Context) !void {
        const in = try ctx.input(Delete);
        if (in.path.id != 1) return error.TodoNotFound;
    }

    pub fn exportCsv(_: *ProjectTodosController, ctx: *http.Context) !void {
        _ = try ctx.input(Export);
        var out = try ctx.response.stream(.{ .content_type = "text/csv" });
        try out.writeAll("id,title\n1,Buy milk\n");
        try out.finish();
    }

    pub fn count(_: *ProjectTodosController, ctx: *http.Context) !void {
        _ = try ctx.input(Count);
        try ctx.response.json(Receipt{ .count = 1 });
    }

    pub fn events(self: *ProjectTodosController, ctx: *http.sse.Context) !void {
        _ = try ctx.input(Events);
        // Without subscribe the stream does not start: 204, which tells an
        // EventSource to stop reconnecting.
        if (ctx.request.header("x-no-stream") != null) return;
        _ = try self.live.subscribe(ctx, "ann");
    }

    pub fn files(_: *ProjectTodosController, ctx: *http.Context) !void {
        const in = try ctx.input(Files);
        try ctx.response.text(in.path.path);
    }
};

pub const SessionController = struct {
    const Login = http.post("/login", .{ .form = LoginForm, .responses = .{ .see_other = .{} } });

    pub const http_routes = http.routes(.{ .prefix = "/session", .methods = .{ .login = Login } });

    pub const openapi: zefir.openapi.ControllerDoc(@This()) = .{
        .tag = "Session",
        .routes = .{ .login = .{ .summary = "Sign in", .responses = .{ .see_other = .{ .description = "Signed in: to the start page." } } } },
    };

    pub fn login(_: *SessionController, ctx: *http.Context) !void {
        const in = try ctx.input(Login);
        if (!std.mem.eql(u8, in.form.password, "secret")) return error.Unauthenticated;
        try ctx.response.status(303).redirect("/");
    }
};

pub const AdminController = struct {
    pub const http_routes = http.routes(.{
        .prefix = "/v1/admin",
        .middleware = .{Federated},
        .methods = .{
            .stats = http.get("/stats", .{ .middleware = .{requireBearer} }),
            .audit = http.get("/audit", .{ .middleware = .{ requireFederated, requirePermission("audit") } }),
        },
    });

    pub const openapi: zefir.openapi.ControllerDoc(@This()) = .{
        .tag = "Admin",
        .routes = .{
            .stats = .{ .summary = "The numbers of the service" },
            .audit = .{ .summary = "The audit log", .deprecated = true },
        },
    };

    pub fn stats(_: *AdminController, _: *http.Context) !http.Json(Receipt) {
        return .{ .value = .{ .count = 1 } };
    }

    pub fn audit(_: *AdminController, _: *http.Context) !void {}
};

pub const AppErrors = struct {
    pub fn mapError(err: anyerror) http.ErrorResponse(ApiError) {
        return switch (err) {
            error.TodoNotFound => .{ .status = 404, .body = .{ .code = "todos.not_found", .message = "No such todo." } },
            else => .fallback(err, .{ .code = http.defaultCode(err), .message = http.defaultTitle(err) }),
        };
    }
};

/// Builds the server and its documents, for the tests. Its prefix comes
/// from a field, as from a config: the documents have no `servers`.
pub const Service = struct {
    prefix: []const u8 = "/api",
    todos: ProjectTodosController = undefined,
    sessions: SessionController = .{},
    admin: AdminController = .{},
    token_auth: TokenAuth = .{},
    app_errors: AppErrors = .{},
    live: http.sse.Manager(LiveEvent) = undefined,
    docs_3_1: zefir.openapi.Document = undefined,
    docs_3_2: zefir.openapi.Document = undefined,
    server: http.Server = undefined,

    pub fn start(s: *Service, gpa: std.mem.Allocator, io: std.Io, backend: http.Backend) !void {
        s.live = .init(gpa, .{});
        errdefer s.live.deinit(io);
        s.todos = .{ .live = &s.live };
        const parts = .{
            .controllers = .{ &s.todos, &s.sessions, &s.admin },
            .middleware = .{&s.token_auth},
            .error_handler = &s.app_errors,
        };
        const info: zefir.openapi.DocumentOptions.Info = .{
            .title = "Projects API",
            .version = "3.0.0",
            .contact = .{ .name = "The projects team", .url = "https://example.com/support", .email = "projects@example.com" },
            .license = .{ .name = "Apache 2.0", .identifier = "Apache-2.0" },
        };
        s.docs_3_1 = comptime zefir.openapi.document(@TypeOf(parts), .{ .info = info });
        s.docs_3_2 = comptime zefir.openapi.document(@TypeOf(parts), .{ .info = info, .version = .@"3.2" });
        s.server = try .init(gpa, parts, .{ .listen = .{ .backend = backend }, .prefix = s.prefix });
        errdefer s.server.deinit(io);
        try s.server.start(io);
    }

    pub fn deinit(s: *Service, io: std.Io) void {
        s.server.deinit(io);
        s.live.deinit(io);
    }
};

const ann: [2][]const u8 = .{ "authorization", "Bearer ann-secret" };
const json: [2][]const u8 = .{ "content-type", "application/json" };
const form: [2][]const u8 = .{ "content-type", "application/x-www-form-urlencoded" };

pub const requests = [_]Request{
    .{ .method = .GET, .target = "/api/v1/projects/7/todos", .headers = &.{ ann, .{ "x-trace", "a" }, .{ "x-trace", "b" }, .{ "cookie", "theme=dark" } }, .status = 200 },
    .{ .method = .GET, .target = "/api/v1/projects/7/todos?limit=5", .headers = &.{ ann, .{ "if-none-match", "\"v1\"" } }, .status = 304 },
    .{ .method = .GET, .target = "/api/v1/projects/7/todos?limit=0", .headers = &.{ann}, .status = 422 },
    .{ .method = .GET, .target = "/api/v1/projects/7/todos", .status = 401 },
    .{ .method = .GET, .target = "/api/v1/projects/7/todos", .headers = &.{ ann, .{ "x-deny", "projects" } }, .status = 403 },
    .{ .method = .GET, .target = "/api/v1/projects/7/todos/1", .headers = &.{ann}, .status = 200 },
    .{ .method = .GET, .target = "/api/v1/projects/7/todos/9", .headers = &.{ann}, .status = 404 },
    .{ .method = .GET, .target = "/api/v1/projects/0/todos/1", .headers = &.{ann}, .status = 422 },
    .{ .method = .POST, .target = "/api/v1/projects/7/todos", .headers = &.{ ann, json }, .body = "{\"title\":\"Buy milk\"}", .status = 201 },
    .{ .method = .POST, .target = "/api/v1/projects/7/todos", .headers = &.{ ann, json, .{ "idempotency-key", "k1" } }, .body = "{\"title\":\"Buy milk\"}", .status = 200 },
    .{ .method = .POST, .target = "/api/v1/projects/7/todos", .headers = &.{ ann, json }, .body = "{\"title\":\"\"}", .status = 422 },
    .{ .method = .DELETE, .target = "/api/v1/projects/7/todos/1", .headers = &.{ann}, .status = 204 },
    .{ .method = .DELETE, .target = "/api/v1/projects/7/todos/1", .headers = &.{ ann, .{ "x-deny", "projects:delete" } }, .status = 403 },
    .{ .method = .GET, .target = "/api/v1/projects/7/todos/export.csv", .headers = &.{ann}, .status = 200 },
    .{ .method = .GET, .target = "/api/v1/projects/7/todos/count", .headers = &.{ann}, .status = 200 },
    .{ .method = .GET, .target = "/api/v1/projects/7/todos/events", .status = 401 },
    .{ .method = .GET, .target = "/api/v1/projects/7/todos/events", .headers = &.{ ann, .{ "x-no-stream", "1" } }, .status = 204 },
    .{ .method = .GET, .target = "/api/v1/projects/7/todos/files/docs/plan.txt", .headers = &.{ann}, .status = 200 },
    .{ .method = .POST, .target = "/api/session/login", .headers = &.{form}, .body = "user=ann&password=secret&remember=true", .status = 303 },
    .{ .method = .POST, .target = "/api/session/login", .headers = &.{form}, .body = "user=ann&password=wrong", .status = 401 },
    .{ .method = .POST, .target = "/api/session/login", .headers = &.{form}, .body = "password=secret", .status = 422 },
    .{ .method = .GET, .target = "/api/v1/admin/stats", .headers = &.{ann}, .status = 200 },
    .{ .method = .GET, .target = "/api/v1/admin/stats", .status = 401 },
    .{ .method = .GET, .target = "/api/v1/admin/audit", .headers = &.{ann}, .status = 204 },
    .{ .method = .GET, .target = "/api/v1/admin/audit", .headers = &.{ ann, .{ "x-deny", "audit" } }, .status = 403 },
};
