//! GET /api/v1/todos/{id}: one route, and its texts for the document.

const zefir = @import("zefir");
const http = zefir.http;
const dto = @import("dto.zig");
const TodoRepository = @import("TodoRepository.zig");

const TodosController = @This();

repo: *const TodoRepository,

// The route has a name, so that the handler reads its input through what
// it declares.
const Get = http.get("/{id}", .{ .path = dto.TodoIdPath });

pub const http_routes = http.routes(.{
    .prefix = "/v1/todos",
    .methods = .{ .get = Get },
});

// The texts of the document: the tag of the controller, and an entry for
// each method of .methods.
pub const openapi: zefir.openapi.ControllerDoc(@This()) = .{
    .tag = "Todos",
    .routes = .{ .get = .{ .summary = "Get a todo" } },
};

pub fn get(self: *TodosController, ctx: *http.Context) !http.Json(dto.TodoResponse) {
    const in = try ctx.input(Get); // in.path is a dto.TodoIdPath, as Get declares
    const todo = self.repo.find(in.path.id) orelse return error.TodoNotFound;
    return .{ .value = .from(todo) };
}
