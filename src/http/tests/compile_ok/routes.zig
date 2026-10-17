//! Must compile: every kind of route and each of its options, declared by
//! client code and passed to Server.init with a prefix from the config.
const std = @import("std");
const http = @import("http");

const TodoResponse = struct { id: u64, title: []const u8 };

const TodosV1Controller = struct {
    calls: u32 = 0,

    pub const http_routes = http.routes(.{
        .prefix = "/v1/todos",
        .middleware = .{.audit},
        .methods = .{
            .list = http.get("", .{}),
            .get = http.get("/{id}", .{}),
            .create = http.post("", .{ .max_body_bytes = 64 << 10, .middleware = .{.audit} }),
            .replace = http.put("/{id}", .{ .timeout = null }),
            .update = http.patch("/{id}", .{}),
            .remove = http.delete("/{id}", .{}),
            .probe = http.head("/{id}", .{}),
            .preflight = http.options("/{id}", .{}),
            .exportCsv = http.get("/export.csv", .{ .timeout = std.Io.Duration.fromSeconds(300) }),
            .files = http.get("/{id}/files/{*path}", .{}),
            .events = http.sse.get("/events", .{ .heartbeat = std.Io.Duration.fromSeconds(15), .on_close = .eventsClosed }),
        },
    });

    pub fn list(_: *TodosV1Controller, _: *http.Context) !void {}
    pub fn get(_: *TodosV1Controller, _: *http.Context) !http.Json(TodoResponse) {
        return .{ .value = .{ .id = 1, .title = "Buy milk" } };
    }
    pub fn create(_: *TodosV1Controller, _: *http.Context) error{TodoLimitReached}!http.Json(TodoResponse) {
        return .{ .value = .{ .id = 2, .title = "Buy bread" }, .status = 201 };
    }
    pub fn replace(_: *TodosV1Controller, _: *http.Context) !void {}
    pub fn update(_: *TodosV1Controller, _: *http.Context) !void {}
    pub fn remove(_: *TodosV1Controller, _: *http.Context) !void {}
    pub fn probe(_: *TodosV1Controller, _: *http.Context) !void {}
    pub fn preflight(_: *TodosV1Controller, _: *http.Context) !void {}
    pub fn exportCsv(_: *TodosV1Controller, _: *http.Context) !void {}
    pub fn files(_: *TodosV1Controller, _: *http.Context) void {}
    pub fn events(_: *TodosV1Controller, _: *http.sse.Context) !void {}
    pub fn eventsClosed(_: *TodosV1Controller, _: *http.sse.Context) void {}
};

const HealthController = struct {
    pub const http_routes = http.routes(.{ .methods = .{ .check = http.get("/health", .{}) } });

    pub fn check(_: *HealthController, _: *http.Context) !void {}
};

fn serve(gpa: std.mem.Allocator, prefix: []const u8) http.Server.InitError!void {
    var todos_v1: TodosV1Controller = .{};
    var health: HealthController = .{};
    const backend: http.Backend = undefined;
    var server = try http.Server.init(gpa, .{ .backend = backend, .prefix = prefix, .controllers = .{ &todos_v1, &health } });
    defer server.deinit(std.testing.io);
    const info: http.RouteInfo = server.routes[0].info;
    _ = info;
}

test {
    try serve(std.testing.allocator, "/api");
}
