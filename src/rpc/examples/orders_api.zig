//! The package orders-api: the contract of the orders service.

const rpc = @import("rpc");
const v = @import("validator");

pub const Item = struct {
    sku: []const u8,
    quantity: u32,
    price_cents: u64,

    pub const field_rules = .{
        .sku = .{ v.notEmpty, v.maxLength(64) },
        .quantity = v.range(1, 99),
    };
};

pub const PlaceOrderRequest = struct {
    user_id: u64,
    items: []const Item,

    // The rules of every item apply too, with paths such as items[1].quantity.
    pub const field_rules = .{ .items = .{ v.minItems(1), v.maxItems(50) } };
};

pub const Order = struct {
    id: u64,
    customer: []const u8,
    total_cents: u64,
};

pub const OrderApi = rpc.Contract(.{
    .name = "orders",
    .version = 1,
    .methods = .{
        .placeOrder = rpc.method(PlaceOrderRequest, Order),
    },
    .errors = .{
        .UnknownUser = .{ .code = .failed_precondition, .app_code = "orders.unknown_user", .message = "No such user" },
        .UsersUnavailable = .{ .code = .unavailable, .app_code = "orders.users_unavailable", .message = "Try again later" },
    },
});

test "the rules of the requests are valid" {
    comptime v.assertRules(PlaceOrderRequest);
}
