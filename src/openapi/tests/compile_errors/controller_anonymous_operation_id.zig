//! Must not compile: a controller of an anonymous type, with a .tag, and a route without an .operation_id:
//! the number the compiler gives an anonymous type changes as the program
//! does.
const zefir = @import("zefir");
const http = zefir.http;

fn Crud(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const http_routes = http.routes(.{ .prefix = "/items", .methods = .{ .list = http.get("", .{}) } });
        pub const openapi: zefir.openapi.ControllerDoc(Self) = .{ .tag = "Items", .routes = .{ .list = .{ .summary = "List the items" } } };

        pub fn list(_: *Self, _: *http.Context) error{}!http.Json([]const T) {
            return .{ .value = &.{} };
        }
    };
}

var items: Crud(struct { id: u64 }) = .{};

test {
    _ = comptime zefir.openapi.document(@TypeOf(.{ .backend = @as(http.Backend, undefined), .controllers = .{&items} }), .{ .info = .{ .title = "Items API", .version = "1.0.0" } });
}
