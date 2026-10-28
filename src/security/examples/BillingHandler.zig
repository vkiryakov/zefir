// Application code (src/BillingHandler.zig of the billing service): zefir-security ships none of these.
//! The handler of billing.v1: it charges an order to the caller, whom the
//! authenticator found by the token. Every method needs a caller.

const rpc = @import("rpc");
const api = @import("billing-api");

const BillingHandler = @This();

pub const rpc_handler = rpc.implement(api.BillingApi, .{
    .defaults = .{ .auth = .required },
});

pub fn charge(_: *BillingHandler, ctx: *rpc.Context, req: api.ChargeRequest) error{Unauthenticated}!api.Charge {
    // `.auth = .required`: an anonymous call never gets here.
    const caller = ctx.identity() orelse return error.Unauthenticated;
    // A real service charges the user here, by caller.subject.
    return .{ .order_id = req.order_id, .customer = caller.subject, .amount_cents = req.amount_cents };
}
