//! Must not compile: two parameters of one name in one place.
const zefir = @import("zefir");
const http = zefir.http;

const ListQuery = struct { limit: u32 = 50 };
const PageQuery = struct { limit: u32 = 20 };

const Paging = struct {
    pub const openapi: zefir.openapi.MiddlewareDoc = .{ .query = PageQuery };

    pub fn run(_: *http.Context) error{}!http.MiddlewareResult {
        return .next;
    }
};
const ItemsController = struct {
    pub const http_routes = http.routes(.{
        .prefix = "/items",
        .methods = .{ .list = http.get("", .{ .query = ListQuery, .middleware = .{Paging} }) },
    });

    pub const openapi: zefir.openapi.ControllerDoc(@This()) = .{ .routes = .{ .list = .{ .summary = "List items" } } };

    pub fn list(_: *ItemsController, _: *http.Context) error{}!void {}
};

var items: ItemsController = .{};

test {
    _ = comptime zefir.openapi.document(@TypeOf(.{ .controllers = .{&items} }), .{ .info = .{ .title = "Todos API", .version = "1.0.0" } });
}
