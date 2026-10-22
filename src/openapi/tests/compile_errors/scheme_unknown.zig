//! Must not compile: a requirement of a scheme that no middleware before it declares.
const zefir = @import("zefir");
const http = zefir.http;

const SessionAuth = struct {
    pub const openapi: zefir.openapi.MiddlewareDoc = .{
        .security_schemes = &.{.{ .name = "session", .kind = .{ .api_key = .{ .in = .cookie, .param = "session" } } }},
    };

    pub fn run(_: *http.Context) error{}!http.MiddlewareResult {
        return .next;
    }
};

const requireBearer = struct {
    pub const openapi: zefir.openapi.MiddlewareDoc = .{ .security = .{ .schemes = &.{"bearer"} } };

    pub fn run(_: *http.Context) error{}!http.MiddlewareResult {
        return .next;
    }
};
const TodosController = struct {
    pub const http_routes = http.routes(.{
        .prefix = "/v1/todos",
        .middleware = .{ SessionAuth, requireBearer },
        .methods = .{ .list = http.get("", .{}) },
    });

    pub const openapi: zefir.openapi.ControllerDoc(@This()) = .{ .routes = .{ .list = .{ .summary = "List todos" } } };

    pub fn list(_: *TodosController, _: *http.Context) error{}!void {}
};

var todos: TodosController = .{};

test {
    _ = comptime zefir.openapi.document(@TypeOf(.{ .controllers = .{&todos} }), .{ .info = .{ .title = "Todos API", .version = "1.0.0" } });
}
