//! Must not compile: the texts of a controller without an entry for one of
//! its routes.
const zefir = @import("zefir");
const http = zefir.http;

const TodoResponse = struct { id: u64 };

const TodosController = struct {
    pub const http_routes = http.routes(.{
        .prefix = "/v1/todos",
        .methods = .{
            .get = http.get("/{id}", .{}),
            .exportCsv = http.get("/export.csv", .{ .responses = .{ .ok = .{ .content_type = "text/csv" } } }),
        },
    });

    pub const openapi: zefir.openapi.ControllerDoc(@This()) = .{
        .routes = .{ .get = .{ .summary = "Get a todo" } },
    };

    pub fn get(_: *TodosController, _: *http.Context) !http.Json(TodoResponse) {
        return .{ .value = .{ .id = 1 } };
    }

    pub fn exportCsv(_: *TodosController, _: *http.Context) !void {}
};

test {
    _ = TodosController.openapi;
}
