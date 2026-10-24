//! Must not compile: two operations of one operationId.
const zefir = @import("zefir");
const http = zefir.http;
const TodosController = struct {
    pub const http_routes = http.routes(.{
        .prefix = "/v1/todos",
        .methods = .{ .list = http.get("", .{}) },
    });

    pub const openapi: zefir.openapi.ControllerDoc(@This()) = .{ .routes = .{ .list = .{ .summary = "List todos", .operation_id = "list" } } };

    pub fn list(_: *TodosController, _: *http.Context) error{}!void {}
};
const UsersController = struct {
    pub const http_routes = http.routes(.{
        .prefix = "/v1/users",
        .methods = .{ .list = http.get("", .{}) },
    });

    pub const openapi: zefir.openapi.ControllerDoc(@This()) = .{ .routes = .{ .list = .{ .summary = "List users", .operation_id = "list" } } };

    pub fn list(_: *UsersController, _: *http.Context) error{}!void {}
};

var todos: TodosController = .{};
var users: UsersController = .{};

test {
    _ = comptime zefir.openapi.document(@TypeOf(.{ .controllers = .{ &todos, &users } }), .{ .info = .{ .title = "Todos API", .version = "1.0.0" } });
}
