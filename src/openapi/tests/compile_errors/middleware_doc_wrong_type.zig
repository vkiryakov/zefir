//! Must not compile: an openapi of a middleware that is not a MiddlewareDoc.
const zefir = @import("zefir");
const http = zefir.http;

const requireUser = struct {
    pub const openapi = .{ .security = .any };

    pub fn run(_: *http.Context) error{}!http.MiddlewareResult {
        return .next;
    }
};
const TodosController = struct {
    pub const http_routes = http.routes(.{
        .prefix = "/v1/todos",
        .middleware = .{requireUser},
        .methods = .{ .list = http.get("", .{}) },
    });

    pub const openapi: zefir.openapi.ControllerDoc(@This()) = .{ .routes = .{ .list = .{ .summary = "List todos" } } };

    pub fn list(_: *TodosController, _: *http.Context) error{}!void {}
};

var todos: TodosController = .{};

test {
    _ = comptime zefir.openapi.document(@TypeOf(.{ .controllers = .{&todos} }), .{ .info = .{ .title = "Todos API", .version = "1.0.0" } });
}
