//! Must not compile: roles with no requirement before them in the chain.
const zefir = @import("zefir");
const http = zefir.http;

fn requirePermission(comptime permission: []const u8) type {
    return struct {
        pub const name = "requirePermission(" ++ permission ++ ")";
        pub const openapi: zefir.openapi.MiddlewareDoc = .{ .roles = &.{permission} };

        pub fn run(_: *http.Context) error{}!http.MiddlewareResult {
            return .next;
        }
    };
}
const TodosController = struct {
    pub const http_routes = http.routes(.{
        .prefix = "/v1/todos",
        .middleware = .{requirePermission("todos")},
        .methods = .{ .list = http.get("", .{}) },
    });

    pub const openapi: zefir.openapi.ControllerDoc(@This()) = .{ .routes = .{ .list = .{ .summary = "List todos" } } };

    pub fn list(_: *TodosController, _: *http.Context) error{}!void {}
};

var todos: TodosController = .{};

test {
    _ = comptime zefir.openapi.document(@TypeOf(.{ .controllers = .{&todos} }), .{ .info = .{ .title = "Todos API", .version = "1.0.0" } });
}
