//! Must not compile: the mistake of the guide of zefir-http in its service,
//! an error handler without the branch of error.TodoLimitReached, which
//! `create` returns, so that only .fallback gives it 500 (the strict error
//! check).
const std = @import("std");
const http = @import("http");

const ApiError = struct { code: []const u8, message: []const u8 };

const AppErrors = struct {
    pub fn mapError(err: anyerror) http.ErrorResponse(ApiError) {
        return switch (err) {
            error.TodoNotFound => .{ .status = 404, .body = .{ .code = "todos.not_found", .message = "Todo not found" } },
            error.ValidationFailed => .{ .status = 422, .body = .{ .code = "validation_failed", .message = "Invalid request" } },
            else => .fallback(err, .{ .code = http.defaultCode(err), .message = http.defaultTitle(err) }),
        };
    }
};

const CreateTodoRequest = struct { title: []const u8 };
const TodoResponse = struct { id: u64, title: []const u8 };

const TodosV1Controller = struct {
    todos: u32 = 0,
    max_todos: u32 = 3,

    const Create = http.post("", .{ .body = CreateTodoRequest, .responses = .{ .created = .{} } });

    pub const http_routes = http.routes(.{
        .prefix = "/v1/todos",
        .methods = .{ .create = Create },
    });

    pub fn create(self: *TodosV1Controller, ctx: *http.Context) !http.Json(TodoResponse) {
        const in = try ctx.input(Create);
        if (self.todos >= self.max_todos) return error.TodoLimitReached;
        self.todos += 1;
        return .{ .value = .{ .id = self.todos, .title = in.body.title }, .status = 201 };
    }
};

test {
    var todos: TodosV1Controller = .{};
    var app_errors: AppErrors = .{};
    var backend: http.testing.Backend = .init(std.testing.allocator);
    defer backend.deinit();
    var server = try http.Server.init(std.testing.allocator, .{ .controllers = .{&todos}, .error_handler = &app_errors }, .{ .listen = .{ .backend = backend.backend() } });
    defer server.deinit(std.testing.io);
}
