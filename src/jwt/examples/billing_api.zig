//! The package billing-api: the contract of the billing service.

const rpc = @import("rpc");
const v = @import("validator");

pub const ChargeRequest = struct {
    order_id: u64,
    amount_cents: u64,

    pub const field_rules = .{
        .order_id = v.positive,
        .amount_cents = v.range(1, 100_000_000),
    };
};

/// An order, charged to the user who placed it.
pub const Charge = struct {
    order_id: u64,
    /// The user of the token: its "sub".
    customer: []const u8,
    amount_cents: u64,
};

pub const BillingApi = rpc.Contract(.{
    .name = "billing",
    .version = 1,
    .methods = .{
        .charge = rpc.method(ChargeRequest, Charge),
    },
});

test "the rules of the requests are valid" {
    comptime v.assertRules(ChargeRequest);
}
