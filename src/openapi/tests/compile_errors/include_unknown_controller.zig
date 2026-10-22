//! Must not compile: an .exclude that names no controller of the server.
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

const HealthController = struct {
    pub const http_routes = http.routes(.{ .methods = .{ .check = http.get("/health", .{}) } });

    pub fn check(_: *HealthController, _: *http.Context) error{}!void {}
};

var todos: TodosController = .{};
var health: HealthController = .{};

test {
    _ = comptime zefir.openapi.document(@TypeOf(.{ .controllers = .{&todos} }), .{ .info = .{ .title = "Todos API", .version = "1.0.0" }, .exclude = &.{HealthController} });
}
