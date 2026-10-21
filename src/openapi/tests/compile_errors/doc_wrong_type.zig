//! Must not compile: an openapi of a DTO that is not its typed Doc.
const zefir = @import("zefir");
const http = zefir.http;

const CreateTodoRequest = struct {
    title: []const u8,

    pub const openapi = .{ .description = "A new todo." };
};
const TodosController = struct {
    pub const http_routes = http.routes(.{
        .prefix = "/v1/todos",
        .methods = .{ .create = http.post("", .{ .body = CreateTodoRequest }) },
    });

    pub const openapi: zefir.openapi.ControllerDoc(@This()) = .{ .routes = .{ .create = .{ .summary = "Create a todo" } } };

    pub fn create(_: *TodosController, _: *http.Context) error{}!void {}
};

var todos: TodosController = .{};

test {
    _ = comptime zefir.openapi.document(@TypeOf(.{ .backend = @as(http.Backend, undefined), .controllers = .{&todos} }), .{ .info = .{ .title = "Todos API", .version = "1.0.0" } });
}
