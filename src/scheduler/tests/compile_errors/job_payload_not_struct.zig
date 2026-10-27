//! Must not compile: a payload is a JSON object, so a struct, not a
//! number.
const scheduler = @import("scheduler");

const SendInvoice = struct {
    pub const scheduler_job: scheduler.Job = .{ .name = "send-invoice" };
    pub const Payload = u64;

    pub fn run(self: *SendInvoice, ctx: *scheduler.Context, payload: Payload) !void {
        _ = self;
        _ = ctx;
        _ = payload;
    }
};

test {
    const ref: scheduler.Ref = .of(SendInvoice, "order-42");
    _ = ref;
}
