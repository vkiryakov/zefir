//! Must not compile: `run` takes its payload as another type than the
//! job's Payload.
const scheduler = @import("scheduler");

const SendInvoice = struct {
    pub const scheduler_job: scheduler.Job = .{ .name = "send-invoice" };
    pub const Payload = struct { order_id: u64 };

    pub fn run(self: *SendInvoice, ctx: *scheduler.Context, order_id: u64) !void {
        _ = self;
        _ = ctx;
        _ = order_id;
    }
};

test {
    const ref: scheduler.Ref = .of(SendInvoice, "order-42");
    _ = ref;
}
