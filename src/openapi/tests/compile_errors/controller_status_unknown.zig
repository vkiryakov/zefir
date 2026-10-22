//! Must not compile: the text of a response of a status that the route
//! does not answer with; it answers 200 only.
const zefir = @import("zefir");
const http = zefir.http;

const TodoResponse = struct { id: u64 };

const TodosController = struct {
    pub const http_routes = http.routes(.{
        .prefix = "/v1/todos",
        .methods = .{ .get = http.get("/{id}", .{}) },
    });

    pub const openapi: zefir.openapi.ControllerDoc(@This()) = .{
        .routes = .{ .get = .{
            .summary = "Get a todo",
            .responses = .{ .created = .{ .description = "A new todo." } },
        } },
    };

    pub fn get(_: *TodosController, _: *http.Context) !http.Json(TodoResponse) {
        return .{ .value = .{ .id = 1 } };
    }
};

test {
    _ = TodosController.openapi;
}
