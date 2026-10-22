//! Must not compile: the mistake of the guide of zefir-openapi in its small
//! application, a route whose path names {todo_id} while its DTO of the
//! path has the field id.
const zefir = @import("zefir");
const http = zefir.http;
const v = zefir.validator;

const TodoIdPath = struct {
    id: u64,

    pub const field_rules = .{ .id = v.positive };
};

const TodosController = struct {
    const Get = http.get("/{todo_id}", .{ .path = TodoIdPath });

    pub const http_routes = http.routes(.{
        .prefix = "/v1/todos",
        .methods = .{ .get = Get },
    });

    pub const openapi: zefir.openapi.ControllerDoc(@This()) = .{
        .tag = "Todos",
        .routes = .{ .get = .{ .summary = "Get a todo" } },
    };

    pub fn get(_: *TodosController, ctx: *http.Context) !void {
        _ = try ctx.input(Get);
    }
};

var todos: TodosController = .{};

test {
    _ = comptime zefir.openapi.document(@TypeOf(.{ .controllers = .{&todos} }), .{ .info = .{ .title = "Todos API", .version = "1.0.0" } });
}
