//! Must not compile: an openapi of a controller that is not its typed ControllerDoc.
const zefir = @import("zefir");
const http = zefir.http;
const TodosController = struct {
    pub const http_routes = http.routes(.{
        .prefix = "/v1/todos",
        .methods = .{ .list = http.get("", .{}) },
    });

    pub const openapi = .{ .tag = "Todos" };

    pub fn list(_: *TodosController, _: *http.Context) error{}!void {}
};

var todos: TodosController = .{};

test {
    _ = comptime zefir.openapi.document(@TypeOf(.{ .controllers = .{&todos} }), .{ .info = .{ .title = "Todos API", .version = "1.0.0" } });
}
