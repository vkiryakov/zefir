//! Must not compile: one tag with two descriptions.
const zefir = @import("zefir");
const http = zefir.http;
const TodosV1Controller = struct {
    pub const http_routes = http.routes(.{
        .prefix = "/v1/todos",
        .methods = .{ .list = http.get("", .{}) },
    });

    pub const openapi: zefir.openapi.ControllerDoc(@This()) = .{ .tag = "Todos", .description = "The todos.", .routes = .{ .list = .{ .summary = "List todos" } } };

    pub fn list(_: *TodosV1Controller, _: *http.Context) error{}!void {}
};
const TodosV2Controller = struct {
    pub const http_routes = http.routes(.{
        .prefix = "/v2/todos",
        .methods = .{ .list = http.get("", .{}) },
    });

    pub const openapi: zefir.openapi.ControllerDoc(@This()) = .{ .tag = "Todos", .description = "The todos, in pages.", .routes = .{ .list = .{ .summary = "List todos" } } };

    pub fn list(_: *TodosV2Controller, _: *http.Context) error{}!void {}
};

var v1: TodosV1Controller = .{};
var v2: TodosV2Controller = .{};

test {
    _ = comptime zefir.openapi.document(@TypeOf(.{ .backend = @as(http.Backend, undefined), .controllers = .{ &v1, &v2 } }), .{ .info = .{ .title = "Todos API", .version = "1.0.0" } });
}
