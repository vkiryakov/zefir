//! Must not compile: an example that breaks a rule of its type.
const zefir = @import("zefir");
const http = zefir.http;
const v = zefir.validator;

const CreateTodoRequest = struct {
    title: []const u8,

    pub const field_rules = .{ .title = v.maxLength(20) };

    pub const openapi: zefir.openapi.Doc(@This()) = .{
        .example = .{ .title = "A title that is far too long" },
    };
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
