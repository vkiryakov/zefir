//! Must not compile: a .name that is not a name of a schema.
const zefir = @import("zefir");
const http = zefir.http;

const TodoItem = struct {
    id: u64,

    pub const openapi: zefir.openapi.Doc(@This()) = .{ .name = "Todo Item" };
};
const TodosController = struct {
    pub const http_routes = http.routes(.{
        .prefix = "/v1/todos",
        .methods = .{ .get = http.get("/{id}", .{}) },
    });

    pub const openapi: zefir.openapi.ControllerDoc(@This()) = .{ .routes = .{ .get = .{ .summary = "Get a todo" } } };

    pub fn get(_: *TodosController, _: *http.Context) error{}!http.Json(TodoItem) {
        return .{ .value = .{ .id = 1 } };
    }
};

var todos: TodosController = .{};

test {
    _ = comptime zefir.openapi.document(@TypeOf(.{ .controllers = .{&todos} }), .{ .info = .{ .title = "Todos API", .version = "1.0.0" } });
}
