//! Must not compile: a type that writes itself, without the .as of its Doc.
const zefir = @import("zefir");
const http = zefir.http;

const Money = struct {
    cents: u64,

    pub fn jsonStringify(self: Money, w: anytype) !void {
        try w.print("\"{d}\"", .{self.cents});
    }
};

const Price = struct { amount: Money };
const PricesController = struct {
    pub const http_routes = http.routes(.{
        .prefix = "/prices",
        .methods = .{ .get = http.get("/{id}", .{}) },
    });

    pub const openapi: zefir.openapi.ControllerDoc(@This()) = .{ .routes = .{ .get = .{ .summary = "Get a price" } } };

    pub fn get(_: *PricesController, _: *http.Context) error{}!http.Json(Price) {
        return .{ .value = .{ .amount = .{ .cents = 100 } } };
    }
};

var prices: PricesController = .{};

test {
    _ = comptime zefir.openapi.document(@TypeOf(.{ .controllers = .{&prices} }), .{ .info = .{ .title = "Todos API", .version = "1.0.0" } });
}
