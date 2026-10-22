//! Must not compile: two different security schemes of one name.
const zefir = @import("zefir");
const http = zefir.http;

const TokenAuth = struct {
    pub const openapi: zefir.openapi.MiddlewareDoc = .{
        .security_schemes = &.{.{ .name = "bearer", .kind = .{ .http = .{ .scheme = "bearer" } } }},
    };

    pub fn run(_: *http.Context) error{}!http.MiddlewareResult {
        return .next;
    }
};

const OtherAuth = struct {
    pub const openapi: zefir.openapi.MiddlewareDoc = .{
        .security_schemes = &.{.{ .name = "bearer", .kind = .{ .http = .{ .scheme = "bearer", .bearer_format = "JWT" } } }},
    };

    pub fn run(_: *http.Context) error{}!http.MiddlewareResult {
        return .next;
    }
};
const TodosController = struct {
    pub const http_routes = http.routes(.{
        .prefix = "/v1/todos",
        .middleware = .{TokenAuth},
        .methods = .{ .list = http.get("", .{ .middleware = .{OtherAuth} }) },
    });

    pub const openapi: zefir.openapi.ControllerDoc(@This()) = .{ .routes = .{ .list = .{ .summary = "List todos" } } };

    pub fn list(_: *TodosController, _: *http.Context) error{}!void {}
};

var todos: TodosController = .{};

test {
    _ = comptime zefir.openapi.document(@TypeOf(.{ .controllers = .{&todos} }), .{ .info = .{ .title = "Todos API", .version = "1.0.0" } });
}
