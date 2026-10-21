//! Must not compile: two types whose schemas would have one name.
const zefir = @import("zefir");
const http = zefir.http;

const v1 = struct {
    pub const Item = struct { id: u64 };
};
const v2 = struct {
    pub const Item = struct { name: []const u8 };
};
const ItemsController = struct {
    pub const http_routes = http.routes(.{
        .prefix = "/items",
        .methods = .{ .old = http.get("/old", .{}), .new = http.get("/new", .{}) },
    });

    pub const openapi: zefir.openapi.ControllerDoc(@This()) = .{ .routes = .{ .old = .{ .summary = "An old item" }, .new = .{ .summary = "A new item" } } };

    pub fn old(_: *ItemsController, _: *http.Context) error{}!http.Json(v1.Item) {
        return .{ .value = .{ .id = 1 } };
    }
    pub fn new(_: *ItemsController, _: *http.Context) error{}!http.Json(v2.Item) {
        return .{ .value = .{ .name = "a" } };
    }
};

var items: ItemsController = .{};

test {
    _ = comptime zefir.openapi.document(@TypeOf(.{ .backend = @as(http.Backend, undefined), .controllers = .{&items} }), .{ .info = .{ .title = "Todos API", .version = "1.0.0" } });
}
