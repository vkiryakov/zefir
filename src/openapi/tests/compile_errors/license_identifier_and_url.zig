//! Must not compile: a license with both its identifier and its URL.
const zefir = @import("zefir");
const http = zefir.http;
const TodosController = struct {
    pub const http_routes = http.routes(.{
        .prefix = "/v1/todos",
        .methods = .{ .list = http.get("", .{}) },
    });

    pub const openapi: zefir.openapi.ControllerDoc(@This()) = .{ .routes = .{ .list = .{ .summary = "List todos" } } };

    pub fn list(_: *TodosController, _: *http.Context) error{}!void {}
};

var todos: TodosController = .{};

test {
    _ = comptime zefir.openapi.document(@TypeOf(.{ .backend = @as(http.Backend, undefined), .controllers = .{&todos} }), .{ .info = .{ .title = "Todos API", .version = "1.0.0", .license = .{ .name = "MIT", .identifier = "MIT", .url = "https://opensource.org/license/mit" } } });
}
