//! The orders of the signed-in user: GET /api/orders. Its routes stand
//! behind `requireUser`, so a request without a user never reaches them.

const http = @import("http");
const auth = @import("auth.zig");

const OrdersController = @This();

pub const http_routes = http.routes(.{
    .prefix = "/orders",
    .middleware = .{auth.requireUser},
    .methods = .{ .list = http.get("", .{}) },
});

pub const Order = struct { id: u64, item: []const u8 };

/// Who the user is, by the claims of their token, and their orders.
pub const OrdersResponse = struct {
    user: []const u8,
    roles: []const []const u8,
    orders: []const Order,
};

pub fn list(_: *OrdersController, ctx: *http.Context) !http.Json(OrdersResponse) {
    // JwtAuth put the user there, from the token.
    const user = try ctx.local(auth.CurrentUser);
    // A real service reads the orders of user.id from its store.
    return .{ .value = .{ .user = user.id, .roles = user.roles, .orders = &.{} } };
}
