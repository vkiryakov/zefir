//! A golden application of zefir-openapi: the small application of design
//! §3, a controller of todos whose errors the error handler answers with
//! `http.Problem`, whose null fields the server leaves out. Its document is
//! src/openapi/tests/golden/todos-3.1.json and -3.2.json.
//!
//! Application code: zefir ships no DTO, controller or error handler.
const std = @import("std");
const zefir = @import("zefir");
const http = zefir.http;
const v = zefir.validator;

pub const Request = @import("request.zig").Request;

/// The errors of the application. The tests of determinism mention them
/// first, in two orders, so that the compiler meets them in each.
pub const TodoError = error{ TodoNotFound, ListNotFound, TodoLocked, TodoArchived };

/// Path /v1/todos/{id}: the field id reads {id}.
pub const TodoIdPath = struct {
    id: u64,

    pub const field_rules = .{ .id = v.positive };

    pub const openapi: zefir.openapi.Doc(@This()) = .{
        .fields = .{ .id = .{ .description = "The id of the todo.", .example = 1 } },
    };
};

pub const TodoResponse = struct {
    id: u64,
    title: []const u8,
    done: bool,

    pub const openapi: zefir.openapi.Doc(@This()) = .{
        .description = "A todo, as the API shows it.",
        .fields = .{
            .id = .{ .description = "The id of the todo." },
            .title = .{ .description = "What to do." },
            .done = .{ .description = "Whether it is done." },
        },
    };
};

pub const CreateTodoRequest = struct {
    title: []const u8,
    list_id: ?u64 = null,

    pub const field_rules = .{
        .title = .{ v.trim, v.notBlank, v.maxLength(200) },
        .list_id = .{ v.rename("listId"), v.positive },
    };

    pub const openapi: zefir.openapi.Doc(@This()) = .{
        .description = "A new todo.",
        .example = .{ .title = "Buy milk" },
        .fields = .{
            .title = .{ .description = "What to do." },
            .list_id = .{ .description = "The list of the todo; none for the inbox.", .example = 1 },
        },
    };
};

pub const TodosController = struct {
    const Get = http.get("/{id}", .{ .path = TodoIdPath });
    const Create = http.post("", .{ .body = CreateTodoRequest, .responses = .{ .created = .{} } });
    const Delete = http.delete("/{id}", .{ .path = TodoIdPath });

    pub const http_routes = http.routes(.{
        .prefix = "/v1/todos",
        .methods = .{ .get = Get, .create = Create, .delete = Delete },
    });

    pub const openapi: zefir.openapi.ControllerDoc(@This()) = .{
        .tag = "Todos",
        .description = "The todos of the inbox and of the lists.",
        .routes = .{
            .get = .{ .summary = "Get a todo" },
            .create = .{ .summary = "Create a todo", .responses = .{ .created = .{ .description = "The todo it made." } } },
            .delete = .{ .summary = "Delete a todo", .description = "A todo that is locked or archived stays." },
        },
    };

    pub fn get(_: *TodosController, ctx: *http.Context) !http.Json(TodoResponse) {
        const in = try ctx.input(Get);
        if (in.path.id != 1) return error.TodoNotFound;
        return .{ .value = .{ .id = 1, .title = "Buy milk", .done = false } };
    }

    pub fn create(_: *TodosController, ctx: *http.Context) !http.Json(TodoResponse) {
        const in = try ctx.input(Create);
        if (in.body.list_id) |list| if (list != 1) return error.ListNotFound;
        return .{ .value = .{ .id = 2, .title = in.body.title, .done = false }, .status = 201 };
    }

    pub fn delete(_: *TodosController, ctx: *http.Context) !void {
        const in = try ctx.input(Delete);
        try remove(in.path.id);
    }

    fn remove(id: u64) TodoError!void {
        return switch (id) {
            1 => error.TodoLocked,
            2 => error.TodoArchived,
            3 => {},
            4 => error.ListNotFound,
            else => error.TodoNotFound,
        };
    }
};

pub const AppErrors = struct {
    pub fn mapError(err: anyerror) http.ErrorResponse(http.Problem) {
        return switch (err) {
            error.TodoNotFound => .{ .status = 404, .body = .{ .title = "Todo not found", .status = 404, .code = "todos.not_found" } },
            error.ListNotFound => .{ .status = 404, .body = .{ .title = "List not found", .status = 404, .code = "lists.not_found" } },
            error.TodoLocked, error.TodoArchived => .{ .status = 409, .body = .{ .title = "The todo cannot change", .status = 409, .code = "todos.frozen" } },
            else => .fallback(err, .{ .title = http.defaultTitle(err), .status = http.defaultStatus(err), .code = http.defaultCode(err) }),
        };
    }
};

/// Builds the server and its documents, for the tests.
pub const Service = struct {
    todos: TodosController = .{},
    app_errors: AppErrors = .{},
    docs_3_1: zefir.openapi.Document = undefined,
    docs_3_2: zefir.openapi.Document = undefined,
    server: http.Server = undefined,

    pub fn start(s: *Service, gpa: std.mem.Allocator, io: std.Io, backend: http.Backend) !void {
        const options = .{
            .backend = backend,
            .prefix = "/api",
            .controllers = .{&s.todos},
            .error_handler = &s.app_errors,
        };
        s.docs_3_1 = comptime zefir.openapi.document(@TypeOf(options), .{ .info = .{ .title = "Todos API", .version = "1.0.0" } });
        s.docs_3_2 = comptime zefir.openapi.document(@TypeOf(options), .{ .info = .{ .title = "Todos API", .version = "1.0.0" }, .version = .@"3.2" });
        s.server = try .init(gpa, options);
        errdefer s.server.deinit(io);
        try s.server.start(io);
    }

    pub fn deinit(s: *Service, io: std.Io) void {
        s.server.deinit(io);
    }
};

const json: [2][]const u8 = .{ "content-type", "application/json" };

pub const requests = [_]Request{
    .{ .method = .GET, .target = "/api/v1/todos/1", .status = 200 },
    .{ .method = .GET, .target = "/api/v1/todos/9", .status = 404 },
    .{ .method = .GET, .target = "/api/v1/todos/0", .status = 422 },
    .{ .method = .GET, .target = "/api/v1/todos/one", .status = 422 },
    .{ .method = .POST, .target = "/api/v1/todos", .headers = &.{json}, .body = "{\"title\":\"Buy milk\"}", .status = 201 },
    .{ .method = .POST, .target = "/api/v1/todos", .headers = &.{json}, .body = "{\"title\":\"Pay rent\",\"listId\":1}", .status = 201 },
    .{ .method = .POST, .target = "/api/v1/todos", .headers = &.{json}, .body = "{\"title\":\"Pay rent\",\"listId\":7}", .status = 404 },
    .{ .method = .POST, .target = "/api/v1/todos", .headers = &.{json}, .body = "{\"title\":\"   \"}", .status = 422 },
    .{ .method = .POST, .target = "/api/v1/todos", .headers = &.{json}, .body = "{\"title\":", .status = 400 },
    .{ .method = .POST, .target = "/api/v1/todos", .headers = &.{.{ "content-type", "text/plain" }}, .body = "Buy milk", .status = 415 },
    .{ .method = .DELETE, .target = "/api/v1/todos/1", .status = 409 },
    .{ .method = .DELETE, .target = "/api/v1/todos/2", .status = 409 },
    .{ .method = .DELETE, .target = "/api/v1/todos/3", .status = 204 },
    .{ .method = .DELETE, .target = "/api/v1/todos/4", .status = 404 },
    .{ .method = .DELETE, .target = "/api/v1/todos/9", .status = 404 },
};
