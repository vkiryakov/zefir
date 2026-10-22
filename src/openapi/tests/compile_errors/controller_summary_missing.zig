//! Must not compile: a route of the document without its summary.
const zefir = @import("zefir");
const http = zefir.http;

const TodoResponse = struct { id: u64 };

const TodosController = struct {
    pub const http_routes = http.routes(.{
        .prefix = "/v1/todos",
        .methods = .{ .get = http.get("/{id}", .{}) },
    });

    pub const openapi: zefir.openapi.ControllerDoc(@This()) = .{
        .routes = .{ .get = .{} },
    };

    pub fn get(_: *TodosController, _: *http.Context) !http.Json(TodoResponse) {
        return .{ .value = .{ .id = 1 } };
    }
};

test {
    _ = TodosController.openapi;
}
