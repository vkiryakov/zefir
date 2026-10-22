//! The contract of the orders over rpc: what the shop serves on NATS, and
//! what its clients call.

const zefir = @import("zefir");
const rpc = zefir.rpc;

pub const Order = struct {
    /// The ObjectId of the order, in hex.
    id: []const u8,
    user_id: u64,
    item: []const u8,
};

pub const GetOrderRequest = struct { id: []const u8 };

pub const OrdersApi = rpc.Contract(.{
    .name = "orders",
    .version = 1,
    .methods = .{ .getOrder = rpc.method(GetOrderRequest, Order) },
    .errors = .{
        .OrderNotFound = .{ .code = .not_found, .app_code = "orders.not_found", .message = "Order not found" },
    },
});
