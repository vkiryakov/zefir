//! Must not compile: a document of a server whose .unknown_fields comes at run time.
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
var unknown: http.Server.UnknownFieldsOptions = .{ .body = .ignore };

test {
    _ = comptime zefir.openapi.document(@TypeOf(.{ .backend = @as(http.Backend, undefined), .controllers = .{&todos}, .unknown_fields = unknown }), .{ .info = .{ .title = "Todos API", .version = "1.0.0" } });
}
